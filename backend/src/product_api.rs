use crate::{
    AppState,
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
pub async fn protect_response(request: Request, next: Next) -> Response {
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
        response.headers_mut().insert("content-security-policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'".parse().unwrap());
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
    blocking(move || {
        let _permit = permit;
        state.product.login(&request.email, &request.password)
    })
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
