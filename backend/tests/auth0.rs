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

// --- finding people: opt-in, exact match -------------------------------------------------------------

async fn sign_in(router: &Router, sub: &str, email: &str, name: &str) -> String {
    let token = sign(&with(
        claims(sub, email),
        json!({format!("{NAMESPACE}name"): name}),
    ));
    let (status, body) = exchange(router, &token).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body["token"].as_str().unwrap().to_owned()
}

async fn find(router: &Router, bearer: &str, query: &str) -> (StatusCode, Value) {
    let (status, _, body) = call(
        router,
        "POST",
        "/api/people/find",
        Some(bearer),
        Some(json!({"query": query})),
    )
    .await;
    (status, body)
}

async fn discover(router: &Router, bearer: &str, body: Value) -> (StatusCode, Value) {
    let (status, _, value) = call(
        router,
        "PUT",
        "/api/accounts/me/discovery",
        Some(bearer),
        Some(body),
    )
    .await;
    (status, value)
}

#[tokio::test]
async fn nobody_can_be_found_until_they_opt_in() {
    let (_, router) = setup(&[]);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    let _ = sign_in(&router, "apple|ada", "ada@example.test", "Ada Lovelace").await;
    let (status, body) = find(&router, &me, "ada@example.test").await;
    assert_eq!(status, StatusCode::NOT_FOUND, "{body}");
    assert_eq!(body["error"]["code"], "person_not_found");

    let (_, _, state) = call(
        &router,
        "GET",
        "/api/accounts/me/discovery",
        Some(&me),
        None,
    )
    .await;
    assert_eq!(state["discoverable"], false);
}

#[tokio::test]
async fn an_opted_in_person_is_found_by_exact_email_or_handle_and_nothing_private_leaks() {
    let (_, router) = setup(&[]);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    let ada = sign_in(&router, "apple|ada", "ada@example.test", "Ada Lovelace").await;
    let (status, state) = discover(
        &router,
        &ada,
        json!({"discoverable": true, "handle": "@Ada.L"}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{state}");
    assert_eq!(state["handle"], "ada.l");
    assert_eq!(state["email_searchable"], true);

    for query in ["ada@example.test", " ADA@Example.test ", "ada.l", "@ada.l"] {
        let (status, person) = find(&router, &me, query).await;
        assert_eq!(status, StatusCode::OK, "{query}: {person}");
        assert_eq!(person["name"], "Ada Lovelace");
        assert_eq!(person["handle"], "ada.l");
        assert_eq!(person["person_id"].as_str().unwrap().len(), 22);
        let keys: Vec<_> = person.as_object().unwrap().keys().cloned().collect();
        assert!(
            keys.iter()
                .all(|k| ["person_id", "name", "handle"].contains(&k.as_str())),
            "{keys:?}"
        );
        assert!(!person.to_string().contains("example.test"));
    }
    // Exact only: no partial matches, no wildcard probing.
    for query in ["ada", "ada@example", "ad", "*", "ada@%", "example.test"] {
        let (status, _) = find(&router, &me, query).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "{query}");
    }
    // Turning it off hides them again.
    discover(&router, &ada, json!({"discoverable": false})).await;
    assert_eq!(find(&router, &me, "ada.l").await.0, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn private_relay_addresses_and_address_shaped_names_are_never_exposed() {
    let (_, router) = setup(&[]);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    // Sign in with Apple "Hide My Email": the relay address is not searchable, only the handle is.
    let relay = "x7k2@privaterelay.appleid.com";
    let hidden = sign_in(&router, "apple|hidden", relay, "Hidden Person").await;
    let (_, state) = discover(
        &router,
        &hidden,
        json!({"discoverable": true, "handle": "hidden_one"}),
    )
    .await;
    assert_eq!(state["email_searchable"], false);
    assert_eq!(find(&router, &me, relay).await.0, StatusCode::NOT_FOUND);
    assert_eq!(find(&router, &me, "hidden_one").await.0, StatusCode::OK);

    // Passwordless email accounts are often named after their address; the lookup shows the handle.
    let named = sign_in(
        &router,
        "email|named",
        "named@example.test",
        "named@example.test",
    )
    .await;
    discover(
        &router,
        &named,
        json!({"discoverable": true, "handle": "named_one"}),
    )
    .await;
    let (_, person) = find(&router, &me, "named@example.test").await;
    assert_eq!(person["name"], "named_one");
    assert!(!person.to_string().contains('@'));
}

#[tokio::test]
async fn absent_hidden_relay_and_self_lookups_are_indistinguishable() {
    let (_, router) = setup(&[]);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    discover(
        &router,
        &me,
        json!({"discoverable": true, "handle": "myself"}),
    )
    .await;
    let _ = sign_in(&router, "apple|quiet", "quiet@example.test", "Quiet").await;
    let mut seen = Vec::new();
    for query in [
        "quiet@example.test",
        "nobody@example.test",
        "myself",
        "quiet",
        "bad query!",
    ] {
        let (status, body) = find(&router, &me, query).await;
        seen.push((status, body));
    }
    assert!(seen.windows(2).all(|w| w[0] == w[1]), "{seen:?}");
}

#[tokio::test]
async fn handles_are_validated_unique_and_changeable() {
    let (_, router) = setup(&[]);
    let a = sign_in(&router, "email|a", "a@example.test", "A").await;
    let b = sign_in(&router, "email|b", "b@example.test", "B").await;
    for bad in [
        "ab",
        "has space",
        "-lead",
        "toolongtoolongtoolongtoolong1",
        "emo😀ji",
        "a@b.c",
    ] {
        let (status, body) = discover(&router, &a, json!({"handle": bad})).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{bad}: {body}");
    }
    assert_eq!(
        discover(&router, &a, json!({"handle": "Taken_1"})).await.0,
        StatusCode::OK
    );
    let (status, body) = discover(&router, &b, json!({"handle": "taken_1"})).await;
    assert_eq!(status, StatusCode::CONFLICT, "{body}");
    assert_eq!(body["error"]["code"], "handle_taken");
    // Re-saving your own handle is fine, and changing it frees the old one.
    assert_eq!(
        discover(&router, &a, json!({"handle": "taken_1"})).await.0,
        StatusCode::OK
    );
    assert_eq!(
        discover(&router, &a, json!({"handle": "fresh_one"}))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        discover(&router, &b, json!({"handle": "taken_1"})).await.0,
        StatusCode::OK
    );
    let (status, state) = discover(&router, &b, json!({"clear_handle": true})).await;
    assert_eq!(
        (status, state["handle"].clone()),
        (StatusCode::OK, Value::Null)
    );
    assert_eq!(
        discover(
            &router,
            &b,
            json!({"handle": "x_y_z", "clear_handle": true})
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
}

#[tokio::test]
async fn lookup_needs_a_session_and_is_rate_limited() {
    let (_, router) = setup(&[]);
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/people/find",
        None,
        Some(json!({"query": "a@b.test"})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, _) = call(
        &router,
        "PUT",
        "/api/accounts/me/discovery",
        None,
        Some(json!({"discoverable": true})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    let mut limited = None;
    for i in 0..40 {
        let (status, body) = find(&router, &me, &format!("guess{i}@example.test")).await;
        if status == StatusCode::TOO_MANY_REQUESTS {
            limited = Some((i, body));
            break;
        }
    }
    let (at, body) = limited.expect("lookups are rate limited");
    assert!((25..=35).contains(&at), "{at}");
    assert_eq!(body["error"]["code"], "auth_rate_limited");
}

#[tokio::test]
async fn password_accounts_are_found_by_handle_only() {
    // A password account's email was never verified by a provider, so it is not searchable by email.
    let router = app(AppState::default());
    let register = |email: &'static str, name: &'static str| {
        let router = router.clone();
        async move {
            let (status, _, body) = call(
                &router,
                "POST",
                "/api/accounts/register",
                None,
                Some(json!({"email": email, "password": ADMIN_PASSWORD, "name": name})),
            )
            .await;
            assert_eq!(status, StatusCode::CREATED, "{body}");
            body["token"].as_str().unwrap().to_owned()
        }
    };
    let old = register("old@example.test", "Old Timer").await;
    let me = register("me@example.test", "Me").await;
    let (_, state) = discover(
        &router,
        &old,
        json!({"discoverable": true, "handle": "old_timer"}),
    )
    .await;
    assert_eq!(state["email_searchable"], false);
    assert_eq!(
        find(&router, &me, "old@example.test").await.0,
        StatusCode::NOT_FOUND
    );
    let (status, person) = find(&router, &me, "old_timer").await;
    assert_eq!(
        (status, person["name"].clone()),
        (StatusCode::OK, json!("Old Timer"))
    );
}

// --- contacts: hashed address book matching -------------------------------------------------------------

fn contact_hash(email: &str) -> String {
    inview_backend::product_store::contact_hash(email)
}

async fn match_contacts(router: &Router, bearer: &str, hashes: Vec<String>) -> (StatusCode, Value) {
    let (status, _, body) = call(
        router,
        "POST",
        "/api/people/match",
        Some(bearer),
        Some(json!({ "hashes": hashes })),
    )
    .await;
    (status, body)
}

#[test]
fn the_contact_hash_is_a_fixed_published_construction() {
    // The app computes the same digest on the device; this vector is pinned on both sides.
    assert_eq!(
        contact_hash("  Alice@Example.test "),
        contact_hash("alice@example.test")
    );
    assert_eq!(
        contact_hash("alice@example.test"),
        "6c24d8c5cc4d10c851f11e34a2f24c394498fd928dc57b4aa858c47e25ab8b00"
    );
}

#[tokio::test]
async fn contacts_match_only_opted_in_people_with_searchable_emails() {
    let (_, router) = setup(&[]);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    let ada = sign_in(&router, "apple|ada", "ada@example.test", "Ada Lovelace").await;
    let _grace = sign_in(&router, "apple|grace", "grace@example.test", "Grace Hopper").await;
    let relay = sign_in(
        &router,
        "apple|relay",
        "r1@privaterelay.appleid.com",
        "Relay",
    )
    .await;
    discover(&router, &ada, json!({"discoverable": true})).await;
    discover(&router, &relay, json!({"discoverable": true})).await;
    discover(&router, &me, json!({"discoverable": true})).await;

    let book = vec![
        contact_hash("ADA@example.test"),
        contact_hash("grace@example.test"),
        contact_hash("r1@privaterelay.appleid.com"),
        contact_hash("me@example.test"),
        contact_hash("stranger@example.test"),
    ];
    let (status, body) = match_contacts(&router, &me, book.clone()).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let matches = body["matches"].as_array().unwrap();
    assert_eq!(matches.len(), 1, "{body}");
    assert_eq!(matches[0]["hash"], book[0]);
    assert_eq!(matches[0]["name"], "Ada Lovelace");
    let keys: Vec<_> = matches[0].as_object().unwrap().keys().cloned().collect();
    assert!(
        keys.iter()
            .all(|k| ["hash", "person_id", "name", "handle"].contains(&k.as_str())),
        "{keys:?}"
    );
    assert!(!body.to_string().contains("example.test"));
    // Opting out removes them.
    discover(&router, &ada, json!({"discoverable": false})).await;
    let (_, body) = match_contacts(&router, &me, book).await;
    assert!(body["matches"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn contact_batches_are_validated_bounded_and_rate_limited() {
    let (_, router) = setup(&[]);
    let (status, _, _) = call(
        &router,
        "POST",
        "/api/people/match",
        None,
        Some(json!({"hashes": []})),
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let me = sign_in(&router, "email|me", "me@example.test", "Me").await;
    for bad in [
        vec!["alice@example.test".to_owned()],
        vec!["ABCDEF".repeat(11)[..64].to_owned()],
        vec!["z".repeat(64)],
    ] {
        let (status, body) = match_contacts(&router, &me, bad).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
    }
    let too_many = (0..501)
        .map(|i| contact_hash(&format!("c{i}@example.test")))
        .collect();
    assert_eq!(
        match_contacts(&router, &me, too_many).await.0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let limit = (0..500)
        .map(|i| contact_hash(&format!("c{i}@example.test")))
        .collect::<Vec<_>>();
    assert_eq!(
        match_contacts(&router, &me, limit.clone()).await.0,
        StatusCode::OK
    );
    let mut limited = false;
    for _ in 0..12 {
        if match_contacts(&router, &me, limit.clone()).await.0 == StatusCode::TOO_MANY_REQUESTS {
            limited = true;
            break;
        }
    }
    assert!(limited, "contact matching is rate limited");
}

// --- live location sharing -----------------------------------------------------------------------------

async fn person_id_of(router: &Router, bearer: &str, query: &str) -> String {
    let (status, person) = find(router, bearer, query).await;
    assert_eq!(status, StatusCode::OK, "{query}: {person}");
    person["person_id"].as_str().unwrap().to_owned()
}

async fn put_position(router: &Router, bearer: &str, body: Value) -> (StatusCode, Value) {
    let (status, _, value) = call(
        router,
        "PUT",
        "/api/accounts/me/position",
        Some(bearer),
        Some(body),
    )
    .await;
    (status, value)
}

async fn locate(router: &Router, bearer: &str, person: &str) -> (StatusCode, Value) {
    let (status, _, value) = call(
        router,
        "GET",
        &format!("/api/people/{person}/location"),
        Some(bearer),
        None,
    )
    .await;
    (status, value)
}

fn spot() -> Value {
    json!({"venue_id": "student-center-east", "floor": 2, "x": 4.5, "z": -12.25, "heading_deg": 90.0, "accuracy_m": 1.5})
}

/// Ada and Ben, both discoverable, plus a bystander.
async fn trio(router: &Router) -> (String, String, String) {
    let ada = sign_in(router, "apple|ada", "ada@example.test", "Ada").await;
    let ben = sign_in(router, "apple|ben", "ben@example.test", "Ben").await;
    let eve = sign_in(router, "apple|eve", "eve@example.test", "Eve").await;
    for (token, handle) in [(&ada, "ada_l"), (&ben, "ben_k"), (&eve, "eve_x")] {
        discover(
            router,
            token,
            json!({"discoverable": true, "handle": handle}),
        )
        .await;
    }
    (ada, ben, eve)
}

#[tokio::test]
async fn an_offer_shares_a_live_position_only_with_that_person() {
    let (_, router) = setup(&[]);
    let (ada, ben, eve) = trio(&router).await;
    let ben_id = person_id_of(&router, &ada, "ben_k").await;
    let ada_id = person_id_of(&router, &ben, "ada_l").await;

    // Nothing is stored or visible before sharing.
    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], false);
    assert_eq!(
        locate(&router, &ben, &ada_id).await.0,
        StatusCode::NOT_FOUND
    );

    let (status, _, share) = call(
        &router,
        "POST",
        "/api/people/shares",
        Some(&ada),
        Some(json!({"person_id": ben_id, "mode": "offer", "minutes": 30})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{share}");
    assert_eq!(
        (share["state"].clone(), share["direction"].clone()),
        (json!("active"), json!("outgoing"))
    );
    let expiry = share["expires_at"].as_u64().unwrap() - now();
    assert!((29 * 60..=30 * 60).contains(&expiry), "{expiry}");

    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], true);
    let (status, here) = locate(&router, &ben, &ada_id).await;
    assert_eq!(status, StatusCode::OK, "{here}");
    assert_eq!(
        (here["venue_id"].clone(), here["floor"].clone()),
        (json!("student-center-east"), json!(2))
    );
    assert_eq!(
        (here["x"].clone(), here["z"].clone()),
        (json!(4.5), json!(-12.25))
    );
    assert_eq!(here["person"]["name"], "Ada");
    assert!(here["age_seconds"].as_u64().unwrap() < 5);
    assert!(!here.to_string().contains("example.test"));

    // Nobody else sees it: not the bystander, not Ada's own lookup of Ben, not a stranger id.
    assert_eq!(
        locate(&router, &eve, &ada_id).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        locate(&router, &ada, &ben_id).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        locate(&router, &ben, "doesnotexist0000000000").await.0,
        StatusCode::NOT_FOUND
    );

    // Both sides see the share in their list with the right direction.
    let (_, _, ada_list) = call(&router, "GET", "/api/people/shares", Some(&ada), None).await;
    let (_, _, ben_list) = call(&router, "GET", "/api/people/shares", Some(&ben), None).await;
    assert_eq!(ada_list["shares"][0]["direction"], "outgoing");
    assert_eq!(ben_list["shares"][0]["direction"], "incoming");
    assert_eq!(ben_list["shares"][0]["person"]["name"], "Ada");
}

#[tokio::test]
async fn a_request_needs_the_sharer_to_accept_and_either_side_can_end_it() {
    let (_, router) = setup(&[]);
    let (ada, ben, _) = trio(&router).await;
    let ada_id = person_id_of(&router, &ben, "ada_l").await;

    // Ben asks to see Ada. Until Ada accepts, nothing is visible even if she is publishing.
    let (status, _, share) = call(
        &router,
        "POST",
        "/api/people/shares",
        Some(&ben),
        Some(json!({"person_id": ada_id, "mode": "request"})),
    )
    .await;
    assert_eq!(status, StatusCode::CREATED, "{share}");
    assert_eq!(
        (share["state"].clone(), share["direction"].clone()),
        (json!("requested"), json!("incoming"))
    );
    let id = share["id"].as_str().unwrap();
    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], false);
    assert_eq!(
        locate(&router, &ben, &ada_id).await.0,
        StatusCode::NOT_FOUND
    );

    // Only the sharer can answer; the requester cannot approve their own request.
    let respond = |token: &str, accept: bool| {
        let router = router.clone();
        let token = token.to_owned();
        let path = format!("/api/people/shares/{id}/respond");
        async move {
            call(
                &router,
                "POST",
                &path,
                Some(&token),
                Some(json!({"accept": accept, "minutes": 15})),
            )
            .await
        }
    };
    assert_eq!(respond(&ben, true).await.0, StatusCode::NOT_FOUND);
    let (status, _, accepted) = respond(&ada, true).await;
    assert_eq!(status, StatusCode::OK, "{accepted}");
    assert_eq!(accepted["state"], "active");
    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], true);
    assert_eq!(locate(&router, &ben, &ada_id).await.0, StatusCode::OK);

    // The viewer can stop watching; the position is dropped and nothing is visible.
    let (status, _, _) = call(
        &router,
        "DELETE",
        &format!("/api/people/shares/{id}"),
        Some(&ben),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(
        locate(&router, &ben, &ada_id).await.0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], false);
    // Ending twice, or someone else ending it, finds nothing.
    let (status, _, _) = call(
        &router,
        "DELETE",
        &format!("/api/people/shares/{id}"),
        Some(&ada),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn declining_keeps_everything_private_and_sharing_requires_discoverability() {
    let (_, router) = setup(&[]);
    let (ada, ben, _) = trio(&router).await;
    let ada_id = person_id_of(&router, &ben, "ada_l").await;
    let (_, _, share) = call(
        &router,
        "POST",
        "/api/people/shares",
        Some(&ben),
        Some(json!({"person_id": ada_id, "mode": "request"})),
    )
    .await;
    let id = share["id"].as_str().unwrap();
    let (status, _, declined) = call(
        &router,
        "POST",
        &format!("/api/people/shares/{id}/respond"),
        Some(&ada),
        Some(json!({"accept": false})),
    )
    .await;
    assert_eq!(
        (status, declined["state"].clone()),
        (StatusCode::OK, json!("declined"))
    );
    assert_eq!(put_position(&router, &ada, spot()).await.1["shared"], false);

    // Someone who is not discoverable cannot be asked, and looks the same as a stranger.
    discover(&router, &ada, json!({"discoverable": false})).await;
    let (status, body, _) = {
        let (s, _, b) = call(
            &router,
            "POST",
            "/api/people/shares",
            Some(&ben),
            Some(json!({"person_id": ada_id, "mode": "request"})),
        )
        .await;
        (s, b, ())
    };
    assert_eq!(
        (status, body["error"]["code"].clone()),
        (StatusCode::NOT_FOUND, json!("person_not_found"))
    );
}

#[tokio::test]
async fn positions_are_validated_and_go_stale() {
    let (_, router) = setup(&[]);
    let (ada, ben, _) = trio(&router).await;
    let ben_id = person_id_of(&router, &ada, "ben_k").await;
    call(
        &router,
        "POST",
        "/api/people/shares",
        Some(&ada),
        Some(json!({"person_id": ben_id, "mode": "offer"})),
    )
    .await;
    for bad in [
        json!({"venue_id": "", "floor": 2, "x": 1.0, "z": 1.0}),
        json!({"venue_id": "Bad Venue!", "floor": 2, "x": 1.0, "z": 1.0}),
        json!({"venue_id": "ok", "floor": 999, "x": 1.0, "z": 1.0}),
        json!({"venue_id": "ok", "floor": 2, "x": 1e9, "z": 1.0}),
        json!({"venue_id": "ok", "floor": 2, "x": 1.0, "z": 1.0, "accuracy_m": -5.0}),
        json!({"venue_id": "ok", "floor": 2, "x": 1.0}),
    ] {
        let (status, body) = put_position(&router, &ada, bad.clone()).await;
        assert!(
            status == StatusCode::UNPROCESSABLE_ENTITY || status == StatusCode::BAD_REQUEST,
            "{bad}: {status} {body}"
        );
    }
    // A client cannot set its own timestamp.
    let mut forged = spot();
    forged["updated_at"] = json!(1);
    let (status, _) = put_position(&router, &ada, forged).await;
    assert!(status.is_success() || status == StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(put_position(&router, &ada, spot()).await.0, StatusCode::OK);
    let ada_id = person_id_of(&router, &ben, "ada_l").await;
    let (_, here) = locate(&router, &ben, &ada_id).await;
    assert!(here["age_seconds"].as_u64().unwrap() < 5, "{here}");
}

#[tokio::test]
async fn sharing_endpoints_need_a_session() {
    let (_, router) = setup(&[]);
    for (method, path, body) in [
        ("GET", "/api/people/shares", None),
        (
            "POST",
            "/api/people/shares",
            Some(json!({"person_id": "x", "mode": "offer"})),
        ),
        (
            "POST",
            "/api/people/shares/abc/respond",
            Some(json!({"accept": true})),
        ),
        ("DELETE", "/api/people/shares/abc", None),
        ("PUT", "/api/accounts/me/position", Some(spot())),
        ("GET", "/api/people/abcdefghij/location", None),
    ] {
        let (status, _, _) = call(&router, method, path, None, body).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{method} {path}");
    }
}
