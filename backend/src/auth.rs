use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode, header::AUTHORIZATION},
    middleware::Next,
    response::Response,
};
use subtle::ConstantTimeEq;

use crate::error::ApiError;

/// No token is allowed for loopback-only development. For public binds, main.rs requires one.
/// Static studio and preview shells disclose no source data; all data endpoints need a token.
pub async fn authorize(
    State(expected): State<Option<Arc<str>>>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, ApiError> {
    let Some(expected) = expected else {
        return Ok(next.run(request).await);
    };
    let path = request.uri().path();
    if matches!(path, "/" | "/studio")
        || path.starts_with("/studio/assets/")
        || (path.starts_with("/scans/") && path.ends_with("/preview"))
    {
        return Ok(next.run(request).await);
    }
    let valid = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|header| header.to_str().ok())
        .and_then(|header| header.strip_prefix("Bearer "))
        .is_some_and(|provided| provided.as_bytes().ct_eq(expected.as_bytes()).into());
    if !valid {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "Bearer token required.",
        ));
    }
    Ok(next.run(request).await)
}
