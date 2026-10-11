//! Auth0 sign-in: token verification, account linking, roles, and the break-glass admin.
//! Tokens are signed with a test-only RSA key (`tests/fixtures/auth0-test-key.pem`) and verified
//! against the matching static JWKS, so nothing here touches the network.
use std::sync::Arc;

use axum::{
    Router,
    body::{Body, to_bytes},
    http::{HeaderMap, Request, StatusCode},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use inview_backend::{
    AppState, app,
    auth0::{Auth0, Auth0Config},
};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode, jwk::JwkSet};
use serde_json::{Value, json};
use tower::ServiceExt;

const DOMAIN: &str = "inview-test.us.auth0.com";
const AUDIENCE: &str = "https://api.inview.test";
const CLIENT_ID: &str = "native-client-id";
const NAMESPACE: &str = "https://inview.app/";
const ADMIN_PASSWORD: &str = "a long test password";

fn key_pem() -> &'static [u8] {
    include_bytes!("fixtures/auth0-test-key.pem")
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

fn config(admin_emails: &[&str]) -> Auth0Config {
    Auth0Config {
        domain: DOMAIN.into(),
        api_audience: Some(AUDIENCE.into()),
        client_id: Some(CLIENT_ID.into()),
        namespace: NAMESPACE.into(),
        admin_emails: admin_emails.iter().map(|e| e.to_string()).collect(),
        admin_client_id: Some("spa-client-id".into()),
    }
}

fn setup(admin_emails: &[&str]) -> (AppState, Router) {
    let jwks: JwkSet = serde_json::from_str(include_str!("fixtures/auth0-test-jwks.json")).unwrap();
    let state = AppState {
        auth0: Some(Arc::new(Auth0::with_static_jwks(
            config(admin_emails),
            jwks,
        ))),
        ..AppState::default()
    };
    state
        .product
        .bootstrap_admin("breakglass@example.test", ADMIN_PASSWORD)
        .unwrap();
    let router = app(state.clone());
    (state, router)
}

/// An access token like the one Auth0 issues after the post-login Action ran.
fn claims(sub: &str, email: &str) -> Value {
    json!({
        "iss": format!("https://{DOMAIN}/"),
        "aud": [AUDIENCE, format!("https://{DOMAIN}/userinfo")],
        "sub": sub,
        "iat": now(),
        "exp": now() + 3600,
        format!("{NAMESPACE}email"): email,
        format!("{NAMESPACE}email_verified"): true,
        format!("{NAMESPACE}name"): "Test Person",
        format!("{NAMESPACE}roles"): [],
    })
}

fn sign(claims: &Value) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some("test-key-1".into());
    encode(
        &header,
        claims,
        &EncodingKey::from_rsa_pem(key_pem()).unwrap(),
    )
    .unwrap()
}

fn with(mut base: Value, patch: Value) -> Value {
    for (k, v) in patch.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

async fn call(
    router: &Router,
    method: &str,
    path: &str,
    bearer: Option<&str>,
    body: Option<Value>,
) -> (StatusCode, HeaderMap, Value) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(token) = bearer {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let request = request
        .header("content-type", "application/json")
        .body(Body::from(
            body.map_or_else(Vec::new, |b| b.to_string().into_bytes()),
        ))
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let (status, headers) = (response.status(), response.headers().clone());
    let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
    let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
    (status, headers, value)
}

async fn exchange(router: &Router, token: &str) -> (StatusCode, Value) {
    let (status, _, body) = call(
        router,
        "POST",
        "/api/accounts/auth0",
        None,
        Some(json!({"access_token": token})),
    )
    .await;
    (status, body)
}

#[tokio::test]
async fn a_valid_token_becomes_a_session_for_a_passwordless_account() {
    let (_, router) = setup(&[]);
    let (status, body) = exchange(&router, &sign(&claims("email|abc", "Ada@Example.test"))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["account"]["email"], "ada@example.test");
    assert_eq!(body["account"]["name"], "Test Person");
    assert_eq!(body["account"]["role"], "user");
    let session = body["token"].as_str().unwrap();
    let (status, _, me) = call(&router, "GET", "/api/accounts/me", Some(session), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["id"], body["account"]["id"]);
    // Ordinary sessions last about two weeks.
    let lifetime = body["expires_at"].as_u64().unwrap() - now();
    assert!(
        lifetime > 13 * 86_400 && lifetime <= 14 * 86_400,
        "{lifetime}"
    );

    // Signing in again keeps the account; the old session is a separate, still-valid one.
    let (_, again) = exchange(&router, &sign(&claims("email|abc", "ada@example.test"))).await;
    assert_eq!(again["account"]["id"], body["account"]["id"]);
    assert_ne!(again["token"], body["token"]);
    let (status, _, _) = call(&router, "GET", "/api/accounts/me", Some(session), None).await;
    assert_eq!(status, StatusCode::OK);

    // A passwordless account has no password to guess.
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/accounts/login",
        None,
        Some(json!({"email": "ada@example.test", "password": "a long test password"})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn the_apps_id_token_signs_in_without_any_api_audience() {
    let (_, router) = setup(&[]);
    // What Auth0 issues the native app: aud = its client ID, standard (un-namespaced) claims.
    let id_token = sign(&json!({
        "iss": format!("https://{DOMAIN}/"), "aud": CLIENT_ID, "sub": "apple|001.abc",
        "iat": now(), "exp": now() + 3600,
        "email": "relay@privaterelay.appleid.com", "email_verified": true, "name": "Apple Person",
    }));
    let (status, _, body) = call(
        &router,
        "POST",
        "/api/accounts/auth0",
        None,
        Some(json!({"id_token": id_token})),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["account"]["email"], "relay@privaterelay.appleid.com");
    assert_eq!(body["account"]["name"], "Apple Person");
    assert_eq!(body["account"]["role"], "user");
    // Exactly one token field is accepted.
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/accounts/auth0",
        None,
        Some(json!({"id_token": id_token, "access_token": id_token})),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/accounts/auth0",
        None,
        Some(json!({})),
    )
    .await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn an_existing_account_links_by_verified_email_and_keeps_its_id() {
    let (state, router) = setup(&[]);
    let existing = state
        .product
        .register("grace@example.test", "another long password", Some("Grace"))
        .unwrap();
    let (status, body) = exchange(&router, &sign(&claims("apple|001", "grace@example.test"))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(
        body["account"]["id"],
        serde_json::to_value(&existing.account.id).unwrap()
    );
    assert_eq!(body["account"]["name"], "Grace", "an existing name is kept");

    // A different sign-in claiming the same email must not take over a linked account.
    let (status, body) =
        exchange(&router, &sign(&claims("email|other", "grace@example.test"))).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "account_linked");
}

#[tokio::test]
async fn an_unverified_email_is_refused_and_creates_nothing() {
    let (_, router) = setup(&["root@example.test"]);
    let token = sign(&with(
        claims("email|squat", "root@example.test"),
        json!({format!("{NAMESPACE}email_verified"): false}),
    ));
    let (status, body) = exchange(&router, &token).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "{body}");
    assert_eq!(body["error"]["code"], "email_not_verified");
    // Nor does the allowlist apply: the verified owner of that email still becomes the admin.
    let (status, body) = exchange(&router, &sign(&claims("apple|root", "root@example.test"))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["account"]["role"], "admin");
}

#[tokio::test]
async fn bad_tokens_are_all_unauthorized() {
    let (_, router) = setup(&[]);
    let good = claims("email|x", "x@example.test");
    let cases: Vec<(&str, String)> = vec![
        (
            "wrong issuer",
            sign(&with(good.clone(), json!({"iss": "https://evil.example/"}))),
        ),
        (
            "wrong audience",
            sign(&with(good.clone(), json!({"aud": "https://other.api"}))),
        ),
        (
            "expired",
            sign(&with(good.clone(), json!({"exp": now() - 3600}))),
        ),
        (
            "issued too long ago",
            sign(&with(good.clone(), json!({"iat": now() - 3600}))),
        ),
        (
            "issued in the future",
            sign(&with(good.clone(), json!({"iat": now() + 3600}))),
        ),
        (
            "another application's ID token",
            sign(&with(good.clone(), json!({"aud": "someone-elses-client"}))),
        ),
        (
            "not yet valid",
            sign(&with(good.clone(), json!({"nbf": now() + 3600}))),
        ),
        ("missing subject", {
            let mut c = good.clone();
            c.as_object_mut().unwrap().remove("sub");
            sign(&c)
        }),
        ("no email", {
            let mut c = good.clone();
            c.as_object_mut()
                .unwrap()
                .remove(&format!("{NAMESPACE}email"));
            sign(&c)
        }),
        ("signed by another key", {
            let mut header = Header::new(Algorithm::RS256);
            header.kid = Some("test-key-1".into());
            let other = include_bytes!("fixtures/auth0-other-key.pem");
            encode(&header, &good, &EncodingKey::from_rsa_pem(other).unwrap()).unwrap()
        }),
        ("unknown key id", {
            let mut header = Header::new(Algorithm::RS256);
            header.kid = Some("rotated-away".into());
            encode(
                &header,
                &good,
                &EncodingKey::from_rsa_pem(key_pem()).unwrap(),
            )
            .unwrap()
        }),
        (
            "no key id",
            encode(
                &Header::new(Algorithm::RS256),
                &good,
                &EncodingKey::from_rsa_pem(key_pem()).unwrap(),
            )
            .unwrap(),
        ),
        ("HS256 with the public modulus as secret", {
            let mut header = Header::new(Algorithm::HS256);
            header.kid = Some("test-key-1".into());
            encode(&header, &good, &EncodingKey::from_secret(b"anything")).unwrap()
        }),
        ("alg none", {
            let b = |v: &Value| URL_SAFE_NO_PAD.encode(v.to_string());
            format!(
                "{}.{}.",
                b(&json!({"alg": "none", "typ": "JWT", "kid": "test-key-1"})),
                b(&good)
            )
        }),
        ("garbage", "not-a-jwt".into()),
        ("oversize", "a".repeat(9 * 1024)),
        ("empty", String::new()),
    ];
    for (name, token) in cases {
        let (status, body) = exchange(&router, &token).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{name}: {body}");
    }
    // Tampered payload with a valid-looking signature.
    let token = sign(&good);
    let parts: Vec<&str> = token.split('.').collect();
    let forged =
        URL_SAFE_NO_PAD.encode(with(good, json!({"sub": "email|someone-else"})).to_string());
    let (status, _) = exchange(&router, &format!("{}.{forged}.{}", parts[0], parts[2])).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn admin_comes_from_the_role_claim_or_the_allowlist_and_is_rederived() {
    let (state, router) = setup(&["lead@example.test"]);
    // Role claim.
    let by_role = sign(&with(
        claims("apple|admin", "ops@example.test"),
        json!({format!("{NAMESPACE}roles"): ["reviewer", "Admin"]}),
    ));
    let (status, admin) = exchange(&router, &by_role).await;
    assert_eq!(status, StatusCode::OK, "{admin}");
    assert_eq!(admin["account"]["role"], "admin");
    // Administrator sessions are short-lived.
    let lifetime = admin["expires_at"].as_u64().unwrap() - now();
    assert!(lifetime <= 8 * 3600 && lifetime > 7 * 3600, "{lifetime}");
    let admin_token = admin["token"].as_str().unwrap().to_owned();
    let (status, _, _) = call(
        &router,
        "GET",
        "/api/admin/submissions",
        Some(&admin_token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

    // Allowlist, case-insensitively, without any role claim.
    let (_, listed) = exchange(&router, &sign(&claims("email|lead", "Lead@Example.test"))).await;
    assert_eq!(listed["account"]["role"], "admin");

    // A user has no admin access.
    let (_, user) = exchange(&router, &sign(&claims("email|plain", "plain@example.test"))).await;
    assert_eq!(user["account"]["role"], "user");
    let (status, _, _) = call(
        &router,
        "GET",
        "/api/admin/submissions",
        Some(user["token"].as_str().unwrap()),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::FORBIDDEN);

    // Remove the role in Auth0: the next sign-in demotes.
    let (_, demoted) = exchange(&router, &sign(&claims("apple|admin", "ops@example.test"))).await;
    assert_eq!(demoted["account"]["role"], "user");

    // The break-glass password administrator keeps admin through an Auth0 sign-in.
    let (status, glass) = exchange(
        &router,
        &sign(&claims("email|glass", "breakglass@example.test")),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{glass}");
    assert_eq!(glass["account"]["role"], "admin");
    drop(state);
}

#[tokio::test]
async fn with_auth0_on_passwords_only_serve_the_bootstrapped_admin() {
    let (state, router) = setup(&[]);
    state
        .product
        .register("pat@example.test", "yet another long password", None)
        .unwrap();
    let login = |email: &'static str, password: &'static str| {
        let router = router.clone();
        async move {
            call(
                &router,
                "POST",
                "/api/accounts/login",
                None,
                Some(json!({"email": email, "password": password})),
            )
            .await
        }
    };
    let (status, _, body) = login("breakglass@example.test", ADMIN_PASSWORD).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["account"]["role"], "admin");
    // Ordinary accounts must use Auth0, even with the right password.
    let (status, _, _) = login("pat@example.test", "yet another long password").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    // New password accounts can no longer be created.
    let (status, _, body) = call(
        &router,
        "POST",
        "/api/accounts/register",
        None,
        Some(json!({"email": "new@example.test", "password": "a brand new long password"})),
    )
    .await;
    assert_eq!(status, StatusCode::GONE, "{body}");
    assert_eq!(body["error"]["code"], "registration_closed");
}

#[tokio::test]
async fn config_and_csp_reflect_the_tenant() {
    let (_, router) = setup(&[]);
    let (status, _, body) = call(&router, "GET", "/api/auth/config", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body,
        json!({"enabled": true, "domain": DOMAIN, "audience": AUDIENCE,
               "client_id": CLIENT_ID, "admin_client_id": "spa-client-id"})
    );
    let request = Request::builder()
        .uri("/admin")
        .body(Body::empty())
        .unwrap();
    let response = router.clone().oneshot(request).await.unwrap();
    let csp = response.headers()["content-security-policy"]
        .to_str()
        .unwrap()
        .to_owned();
    assert!(
        csp.contains(&format!("connect-src 'self' https://{DOMAIN};")),
        "{csp}"
    );
    assert!(csp.contains("frame-ancestors 'none'"));
}

#[tokio::test]
async fn without_a_tenant_nothing_changes() {
    let router = app(AppState::default());
    let (status, _, body) = call(&router, "GET", "/api/auth/config", None, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, json!({"enabled": false}));
    let (status, _, body) = call(
        &router,
        "POST",
        "/api/accounts/auth0",
        None,
        Some(json!({"access_token": "whatever"})),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(body["error"]["code"], "auth0_disabled");
    // Passwords still register and sign in.
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/accounts/register",
        None,
        Some(json!({"email": "old@example.test", "password": "a long test password"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED);
    let request = Request::builder()
        .uri("/admin")
        .body(Body::empty())
        .unwrap();
    let response = router.oneshot(request).await.unwrap();
    assert!(
        response.headers()["content-security-policy"]
            .to_str()
            .unwrap()
            .contains("connect-src 'self';")
    );
}
