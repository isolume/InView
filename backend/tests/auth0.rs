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
    auth0::{Auth0, Auth0Config, Fetcher, KeyTiming, VerifyError},
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
    let other = state
        .product
        .register("other@example.test", ADMIN_PASSWORD, None)
        .unwrap();
    let (status, _, submission) = call(
        &router,
        "POST",
        "/api/submissions",
        Some(&existing.token),
        Some(json!({
            "client_submission_id": "ec3b4471-a95e-4b64-b9fd-73d2d43c7393",
            "venue_id": "student-center-east", "floor": 2, "authorized_space": true,
            "map": {"createdAt": "2026-10-10T12:00:00Z", "floorY": 0,
                "footprints": [{"kind": "floor", "center": [0, 0], "size": [10, 10], "yaw": 0}],
                "points": [], "requiresMeasuredFloorCoverage": true}
        })),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{submission}");
    let (status, _, submission) = call(
        &router,
        "GET",
        &format!("/api/submissions/{}", submission["id"].as_str().unwrap()),
        Some(&existing.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, body) = exchange(&router, &sign(&claims("apple|001", "grace@example.test"))).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, _, retained) = call(
        &router,
        "GET",
        &format!("/api/submissions/{}", submission["id"].as_str().unwrap()),
        body["token"].as_str(),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{retained}");
    assert_eq!(
        retained, submission,
        "linking must not change submission ownership or evidence"
    );
    assert!(
        state.product.account(&other.token).is_ok(),
        "unrelated sessions remain valid"
    );
    assert_eq!(
        body["account"]["id"],
        serde_json::to_value(&existing.account.id).unwrap()
    );
    assert_eq!(body["account"]["name"], "Grace", "an existing name is kept");
    // A session issued before ownership was verified cannot survive linking.
    let (status, _, _) = call(
        &router,
        "GET",
        "/api/accounts/me",
        Some(&existing.token),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, _) = call(
        &router,
        "GET",
        "/api/accounts/me",
        body["token"].as_str(),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);

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
    assert!(body["expires_at"].as_u64().unwrap() - now() <= 8 * 3600);
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

// ---- Key set caching, rotation and outages (the remote fetch path, without a network) ----

use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;

/// A tenant whose key set can be swapped or taken down, counting every fetch.
struct Tenant {
    keys: Mutex<Option<JwkSet>>,
    fetches: AtomicUsize,
}

fn jwks(json: &str) -> JwkSet {
    serde_json::from_str(json).unwrap()
}

fn tenant_with(keys: &str) -> Arc<Tenant> {
    Arc::new(Tenant {
        keys: Mutex::new(Some(jwks(keys))),
        fetches: AtomicUsize::new(0),
    })
}

fn verifier(tenant: &Arc<Tenant>, timing: KeyTiming) -> Auth0 {
    let source = tenant.clone();
    let fetcher: Fetcher = Arc::new(move || {
        let source = source.clone();
        Box::pin(async move {
            source.fetches.fetch_add(1, Ordering::SeqCst);
            source.keys.lock().unwrap().clone()
        })
    });
    Auth0::with_fetcher(config(&[]), fetcher, timing)
}

fn timing(ttl_ms: u64, forced_ms: u64, backoff_ms: u64) -> KeyTiming {
    KeyTiming {
        ttl: Duration::from_millis(ttl_ms),
        forced_refresh_interval: Duration::from_millis(forced_ms),
        failure_backoff: Duration::from_millis(backoff_ms),
    }
}

fn token_signed_by(pem: &[u8], kid: &str) -> String {
    let mut header = Header::new(Algorithm::RS256);
    header.kid = Some(kid.into());
    let claims = claims("email|k", "k@example.test");
    encode(&header, &claims, &EncodingKey::from_rsa_pem(pem).unwrap()).unwrap()
}

#[tokio::test]
async fn keys_are_cached_between_sign_ins() {
    let tenant = tenant_with(include_str!("fixtures/auth0-test-jwks.json"));
    let auth0 = verifier(&tenant, timing(60_000, 60_000, 60_000));
    let token = sign(&claims("email|c", "c@example.test"));
    for _ in 0..3 {
        auth0.verify(&token).await.unwrap();
    }
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_expired_cache_is_refetched() {
    let tenant = tenant_with(include_str!("fixtures/auth0-test-jwks.json"));
    let auth0 = verifier(&tenant, timing(30, 60_000, 60_000));
    let token = sign(&claims("email|c", "c@example.test"));
    auth0.verify(&token).await.unwrap();
    tokio::time::sleep(Duration::from_millis(60)).await;
    auth0.verify(&token).await.unwrap();
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn a_rotated_key_is_picked_up_and_unknown_keys_cannot_hammer_the_tenant() {
    let tenant = tenant_with(include_str!("fixtures/auth0-test-jwks.json"));
    let auth0 = verifier(&tenant, timing(60_000, 60_000, 60_000));
    auth0
        .verify(&sign(&claims("email|c", "c@example.test")))
        .await
        .unwrap();
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 1);

    // Auth0 rotates: the new key's id is unknown to the cache, which refetches and accepts it.
    *tenant.keys.lock().unwrap() = Some(jwks(include_str!("fixtures/auth0-rotated-jwks.json")));
    let rotated = token_signed_by(
        include_bytes!("fixtures/auth0-other-key.pem"),
        "rotated-key",
    );
    assert!(auth0.verify(&rotated).await.is_ok());
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 2);

    // A flood of unknown key ids is rate-limited to the interval: no further fetches.
    let bogus = token_signed_by(key_pem(), "does-not-exist");
    for _ in 0..20 {
        assert_eq!(
            auth0.verify(&bogus).await,
            Err(VerifyError::Invalid("unknown signing key"))
        );
    }
    assert_eq!(
        tenant.fetches.load(Ordering::SeqCst),
        2,
        "forced refresh was rate-limited"
    );
}

#[tokio::test]
async fn an_outage_serves_stale_keys_and_backs_off() {
    let tenant = tenant_with(include_str!("fixtures/auth0-test-jwks.json"));
    let auth0 = verifier(&tenant, timing(30, 60_000, 250));
    let token = sign(&claims("email|c", "c@example.test"));
    auth0.verify(&token).await.unwrap();
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 1);

    // The cache expires while the tenant is unreachable: keep verifying with the stale keys.
    *tenant.keys.lock().unwrap() = None;
    tokio::time::sleep(Duration::from_millis(60)).await;
    for _ in 0..10 {
        auth0.verify(&token).await.unwrap();
    }
    assert_eq!(
        tenant.fetches.load(Ordering::SeqCst),
        2,
        "one failed attempt, then backoff"
    );

    // After the backoff, and once the tenant is back, keys are fetched again.
    *tenant.keys.lock().unwrap() = Some(jwks(include_str!("fixtures/auth0-test-jwks.json")));
    tokio::time::sleep(Duration::from_millis(300)).await;
    auth0.verify(&token).await.unwrap();
    assert_eq!(tenant.fetches.load(Ordering::SeqCst), 3);
}

#[tokio::test]
async fn with_no_keys_the_exchange_is_unavailable_not_unauthorized() {
    let tenant = Arc::new(Tenant {
        keys: Mutex::new(None),
        fetches: AtomicUsize::new(0),
    });
    let auth0 = verifier(&tenant, timing(60_000, 60_000, 60_000));
    let token = sign(&claims("email|c", "c@example.test"));
    assert_eq!(auth0.verify(&token).await, Err(VerifyError::Unavailable));

    // Through HTTP that is a 503, so the app says "try again" rather than "sign-in refused".
    let state = AppState {
        auth0: Some(Arc::new(verifier(&tenant, timing(60_000, 60_000, 60_000)))),
        ..AppState::default()
    };
    let (status, body) = exchange(&app(state), &token).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert_eq!(body["error"]["code"], "auth_unavailable");

    // An empty key set is an outage too, never "no key matches".
    *tenant.keys.lock().unwrap() = Some(JwkSet { keys: vec![] });
    let auth0 = verifier(&tenant, timing(60_000, 60_000, 60_000));
    assert_eq!(auth0.verify(&token).await, Err(VerifyError::Unavailable));
}

#[tokio::test]
async fn legacy_password_account_promotion_revokes_old_tokens_and_does_not_grant_breakglass() {
    let (state, router) = setup(&[]);
    let existing = state
        .product
        .register("legacy@example.test", ADMIN_PASSWORD, None)
        .unwrap();
    let plain = claims("email|legacy", "legacy@example.test");
    let (status, linked) = exchange(&router, &sign(&plain)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(linked["account"]["id"], existing.account.id);
    let (status, admin) = exchange(
        &router,
        &sign(&with(
            plain.clone(),
            json!({format!("{NAMESPACE}roles"): ["admin"]}),
        )),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(admin["account"]["role"], "admin");
    assert!(admin["expires_at"].as_u64().unwrap() - now() <= 8 * 3600);
    for token in [&existing.token, linked["token"].as_str().unwrap()] {
        for path in ["/api/accounts/me", "/api/admin/submissions"] {
            assert_eq!(
                call(&router, "GET", path, Some(token), None).await.0,
                StatusCode::UNAUTHORIZED
            );
        }
    }
    assert_eq!(
        call(
            &router,
            "GET",
            "/api/admin/submissions",
            admin["token"].as_str(),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
    // A retained password is not proof of explicit bootstrap provisioning, even while admin.
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/accounts/login",
            None,
            Some(json!({"email": "legacy@example.test", "password": ADMIN_PASSWORD}))
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (status, demoted) = exchange(&router, &sign(&plain)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(demoted["account"]["role"], "user");
    assert_eq!(
        call(
            &router,
            "GET",
            "/api/admin/submissions",
            admin["token"].as_str(),
            None
        )
        .await
        .0,
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        call(
            &router,
            "POST",
            "/api/accounts/login",
            None,
            Some(json!({"email": "legacy@example.test", "password": ADMIN_PASSWORD}))
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn first_link_with_admin_claim_revokes_preregistered_attackers_session() {
    let (state, router) = setup(&["owner@example.test"]);
    let attacker = state
        .product
        .register("owner@example.test", ADMIN_PASSWORD, None)
        .unwrap();
    let (status, owner) =
        exchange(&router, &sign(&claims("apple|owner", "owner@example.test"))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(owner["account"]["id"], attacker.account.id);
    assert_eq!(owner["account"]["role"], "admin");
    for path in ["/api/accounts/me", "/api/admin/submissions"] {
        assert_eq!(
            call(&router, "GET", path, Some(&attacker.token), None)
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        call(
            &router,
            "GET",
            "/api/admin/submissions",
            owner["token"].as_str(),
            None
        )
        .await
        .0,
        StatusCode::OK
    );
}
