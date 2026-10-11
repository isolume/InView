use crate::{
    AppState,
    auth0::VerifyError,
    error::ApiError,
    product_store::{
        self, Account, AuthResponse, EditRequest, PublishRequest, PublishedMap, Role, Submission,
        VENUE_ID,
    },
};
use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode, header},
    response::Html,
};
use axum::{extract::Request, middleware::Next, response::Response};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegisterRequest {
    email: String,
    password: String,
    name: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LoginRequest {
    email: String,
    password: String,
}
fn token(headers: &HeaderMap) -> Result<&str, ApiError> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or_else(product_store::unauthorized)
}
fn account(state: &AppState, headers: &HeaderMap) -> Result<Account, ApiError> {
    state.product.account(token(headers)?)
}
pub(crate) fn admin(state: &AppState, headers: &HeaderMap) -> Result<Account, ApiError> {
    let account = account(state, headers)?;
    if account.role != Role::Admin {
        return Err(product_store::forbidden());
    }
    Ok(account)
}
fn json_error(error: JsonRejection) -> ApiError {
    if error.status() == StatusCode::PAYLOAD_TOO_LARGE {
        return ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "submission_too_large",
            "This map is too large to send. Your saved scan has been kept.",
        );
    }
    ApiError::new(
        error.status(),
        "invalid_json",
        "This request could not be read.",
    )
}
pub async fn protect_response(
    State(state): State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    let is_api = !request.uri().path().starts_with("/studio/assets/");
    let is_admin = request.uri().path() == "/admin";
    let mut response = next.run(request).await;
    if is_api || is_admin {
        response
            .headers_mut()
            .insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
        response
            .headers_mut()
            .insert("x-content-type-options", "nosniff".parse().unwrap());
        response
            .headers_mut()
            .insert("referrer-policy", "no-referrer".parse().unwrap());
    }
    if is_admin {
        // The admin page signs in with Auth0 (PKCE, code exchange at the tenant's token endpoint).
        let connect = match &state.auth0 {
            Some(auth0) => format!("'self' https://{}", auth0.config().domain),
            None => "'self'".to_owned(),
        };
        let policy = format!(
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src {connect}; frame-ancestors 'none'; base-uri 'none'; object-src 'none'"
        );
        if let Ok(value) = policy.parse() {
            response
                .headers_mut()
                .insert("content-security-policy", value);
        }
    }
    response
}
async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> Result<T, ApiError> + Send + 'static,
) -> Result<T, ApiError> {
    tokio::task::spawn_blocking(f).await.map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "request_failed",
            "This request could not be completed.",
        )
    })?
}
pub async fn register(
    State(state): State<AppState>,
    payload: Result<Json<RegisterRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<AuthResponse>), ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    if state.auth0.is_some() {
        return Err(ApiError::new(
            StatusCode::GONE,
            "registration_closed",
            "Create your account by signing in with Apple or your email.",
        ));
    }
    let permit = state
        .product
        .auth_workers
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "auth_busy",
                "Sign-in is busy. Try again shortly.",
            )
        })?;
    blocking(move || {
        let _permit = permit;
        state
            .product
            .register(&request.email, &request.password, request.name.as_deref())
    })
    .await
    .map(|response| (StatusCode::CREATED, Json(response)))
}
pub async fn login(
    State(state): State<AppState>,
    payload: Result<Json<LoginRequest>, JsonRejection>,
) -> Result<Json<AuthResponse>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let permit = state
        .product
        .auth_workers
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "auth_busy",
                "Sign-in is busy. Try again shortly.",
            )
        })?;
    let auth0_enabled = state.auth0.is_some();
    blocking(move || {
        let _permit = permit;
        // With Auth0 enabled, passwords remain only for the bootstrapped administrator.
        state
            .product
            .login_with(&request.email, &request.password, auth0_enabled)
    })
    .await
    .map(Json)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Auth0Request {
    /// The app's ID token (audience = its client ID), or an access token for the configured API.
    #[serde(default)]
    id_token: Option<String>,
    #[serde(default)]
    access_token: Option<String>,
}
/// Trades a verified Auth0 token for the backend's own revocable session.
pub async fn auth0_exchange(
    State(state): State<AppState>,
    payload: Result<Json<Auth0Request>, JsonRejection>,
) -> Result<Json<AuthResponse>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let Some(auth0) = state.auth0.clone() else {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "auth0_disabled",
            "Sign-in with Apple or email isn't enabled on this server.",
        ));
    };
    let token = match (&request.id_token, &request.access_token) {
        (Some(token), None) | (None, Some(token)) => token.clone(),
        _ => {
            return Err(ApiError::invalid(
                "Send exactly one of id_token or access_token.",
            ));
        }
    };
    let identity = auth0.verify(&token).await.map_err(|error| match error {
        VerifyError::Unavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "auth_unavailable",
            "Sign-in is unavailable right now. Try again shortly.",
        ),
        VerifyError::Invalid(reason) => {
            tracing::debug!(reason, "Auth0 token rejected");
            ApiError::new(
                StatusCode::UNAUTHORIZED,
                "invalid_token",
                "This sign-in could not be verified.",
            )
        }
    })?;
    // A verified address is what links accounts; Apple and email codes always provide one.
    if !identity.email_verified {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "email_not_verified",
            "Verify your email address with your sign-in provider and try again.",
        ));
    }
    let admin = auth0.is_admin(&identity);
    blocking(move || {
        state.product.sign_in_external(
            &identity.sub,
            &identity.email,
            identity.name.as_deref(),
            admin,
        )
    })
    .await
    .map(Json)
}
/// What a client needs to start Auth0 sign-in; public values only.
pub async fn auth_config(State(state): State<AppState>) -> Json<Value> {
    Json(match &state.auth0 {
        Some(auth0) => {
            let config = auth0.config();
            json!({"enabled": true, "domain": config.domain, "audience": config.api_audience,
                   "client_id": config.client_id, "admin_client_id": config.admin_client_id})
        }
        None => json!({"enabled": false}),
    })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiscoveryRequest {
    #[serde(default)]
    discoverable: Option<bool>,
    /// A new handle to be found by.
    #[serde(default)]
    handle: Option<String>,
    /// Remove the handle.
    #[serde(default)]
    clear_handle: bool,
}
pub async fn discovery(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<product_store::Discovery>, ApiError> {
    let account = account(&state, &headers)?;
    blocking(move || state.product.discovery(&account))
        .await
        .map(Json)
}
pub async fn set_discovery(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<DiscoveryRequest>, JsonRejection>,
) -> Result<Json<product_store::Discovery>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    let handle = match (request.handle, request.clear_handle) {
        (Some(_), true) => {
            return Err(ApiError::invalid("Send either handle or clear_handle."));
        }
        (Some(handle), false) => Some(Some(handle)),
        (None, true) => Some(None),
        (None, false) => None,
    };
    blocking(move || {
        state
            .product
            .set_discovery(&account, request.discoverable, handle)
    })
    .await
    .map(Json)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FindPersonRequest {
    query: String,
}
pub async fn find_person(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<FindPersonRequest>, JsonRejection>,
) -> Result<Json<product_store::Person>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    if request.query.len() > 254 {
        return Err(ApiError::invalid("Enter an email address or handle."));
    }
    blocking(move || state.product.find_person(&account, &request.query))
        .await
        .map(Json)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MatchContactsRequest {
    hashes: Vec<String>,
}
pub async fn match_contacts(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<MatchContactsRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    let matches = blocking(move || state.product.match_contacts(&account, &request.hashes)).await?;
    Ok(Json(json!({ "matches": matches })))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartShareRequest {
    person_id: String,
    mode: product_store::people::ShareMode,
    #[serde(default)]
    minutes: Option<u64>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RespondShareRequest {
    accept: bool,
    #[serde(default)]
    minutes: Option<u64>,
}
pub async fn list_shares(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let account = account(&state, &headers)?;
    let shares = blocking(move || state.product.list_shares(&account)).await?;
    Ok(Json(json!({ "shares": shares })))
}
pub async fn start_share(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<StartShareRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<product_store::people::ShareView>), ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    let view = blocking(move || {
        state
            .product
            .start_share(&account, &request.person_id, request.mode, request.minutes)
    })
    .await?;
    Ok((StatusCode::CREATED, Json(view)))
}
pub async fn respond_share(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    payload: Result<Json<RespondShareRequest>, JsonRejection>,
) -> Result<Json<product_store::people::ShareView>, ApiError> {
    let Json(request) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    blocking(move || {
        state
            .product
            .respond_share(&account, &id, request.accept, request.minutes)
    })
    .await
    .map(Json)
}
pub async fn end_share(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let account = account(&state, &headers)?;
    blocking(move || state.product.end_share(&account, &id)).await?;
    Ok(StatusCode::NO_CONTENT)
}
pub async fn publish_position(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<product_store::people::Position>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(position) = payload.map_err(json_error)?;
    let account = account(&state, &headers)?;
    let shared = blocking(move || state.product.publish_position(&account, position)).await?;
    Ok(Json(json!({ "shared": shared })))
}
pub async fn person_location(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(person): Path<String>,
) -> Result<Json<product_store::people::PersonLocation>, ApiError> {
    let account = account(&state, &headers)?;
    blocking(move || state.product.person_location(&account, &person))
        .await
        .map(Json)
}
pub async fn me(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Account>, ApiError> {
    account(&state, &headers).map(Json)
}
pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let token = token(&headers)?.to_string();
    blocking(move || state.product.logout(&token)).await?;
    Ok(StatusCode::NO_CONTENT)
}
fn summary(submission: &Submission) -> Value {
    json!({"id":submission.id,"owner_id":submission.owner_id,"venue_id":submission.venue_id,"floor":submission.floor,"title":submission.title,"notes":submission.notes,"status":submission.status,"revision":submission.revision,"created_at":submission.created_at,"updated_at":submission.updated_at,"review_note":submission.review_note,"published_version":submission.published_version})
}
pub async fn list(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<Value>>, ApiError> {
    let account = account(&state, &headers)?;
    Ok(Json(
        state
            .product
            .list(&account, false)?
            .iter()
            .map(summary)
            .collect(),
    ))
}
pub async fn admin_list(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<Value>>, ApiError> {
    let account = admin(&state, &headers)?;
    Ok(Json(
        state
            .product
            .list(&account, true)?
            .iter()
            .map(summary)
            .collect(),
    ))
}
pub async fn get(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Submission>, ApiError> {
    let account = account(&state, &headers)?;
    state.product.get(&account, &id).map(Json)
}
pub async fn submit(
    State(state): State<AppState>,
    headers: HeaderMap,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let account = account(&state, &headers)?;
    let Json(value) = payload.map_err(json_error)?;
    let (created, submission) = blocking(move || state.product.submit(&account, value)).await?;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(summary(&submission)),
    ))
}
pub async fn resubmit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    payload: Result<Json<Value>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let account = account(&state, &headers)?;
    let Json(value) = payload.map_err(json_error)?;
    let (created, submission) =
        blocking(move || state.product.resubmit(&account, &id, value)).await?;
    Ok((
        if created {
            StatusCode::CREATED
        } else {
            StatusCode::OK
        },
        Json(summary(&submission)),
    ))
}
pub async fn edit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    payload: Result<Json<EditRequest>, JsonRejection>,
) -> Result<Json<Submission>, ApiError> {
    let account = admin(&state, &headers)?;
    let Json(request) = payload.map_err(json_error)?;
    blocking(move || state.product.edit(&account, &id, request))
        .await
        .map(Json)
}
fn public_release(release: PublishedMap) -> Value {
    json!({"id":release.id,"submission_id":release.submission_id,"venue_id":release.venue_id,"floor":release.floor,"version":release.version,"map_revision":release.source_revision,"source_revision":release.source_revision,"published_at":release.published_at,"origin":"admin_reviewed","map":release.map,"ar_ready":false})
}
pub async fn publish(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    payload: Result<Json<PublishRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let account = admin(&state, &headers)?;
    let Json(request) = payload.map_err(json_error)?;
    blocking(move || state.product.publish(&account, &id, request))
        .await
        .map(|release| Json(public_release(release)))
}
fn check_venue(id: &str) -> Result<(), ApiError> {
    if id != VENUE_ID {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "venue_not_found",
            "This building is not available.",
        ));
    }
    Ok(())
}
pub async fn maps(
    State(state): State<AppState>,
    Path(venue): Path<String>,
) -> Result<Json<Value>, ApiError> {
    check_venue(&venue)?;
    let maps: Vec<_> = state
        .product
        .published()?
        .into_iter()
        .map(public_release)
        .collect();
    Ok(Json(
        json!({"venue_id":VENUE_ID,"name":"Student Center East","maps":maps}),
    ))
}
pub async fn version(
    State(state): State<AppState>,
    Path((venue, floor, version)): Path<(String, u8, u64)>,
) -> Result<Json<Value>, ApiError> {
    check_venue(&venue)?;
    state
        .product
        .version(floor, version)
        .map(|release| Json(public_release(release)))
}
pub async fn admin_workspace() -> Html<&'static str> {
    Html(include_str!("../public/admin.html"))
}
