use std::sync::Arc;

use axum::{
    body::Body,
    extract::State,
    http::{HeaderMap, Request, StatusCode, header::AUTHORIZATION},
    middleware::Next,
    response::Response,
};
use subtle::ConstantTimeEq;

use crate::error::ApiError;

/// No token is allowed for loopback-only development. For public binds, main.rs requires one.
/// Applied only to processing routes. Product routes keep their own account/role checks.
pub async fn authorize(
    State(expected): State<Option<Arc<str>>>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, ApiError> {
    if !processing_access(expected.as_deref(), request.headers()) {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "Bearer token required.",
        ));
    }
    Ok(next.run(request).await)
}

/// An unconfigured token is allowed only by loopback executable startup (and isolated tests).
pub fn processing_access(expected: Option<&str>, headers: &HeaderMap) -> bool {
    let Some(expected) = expected else {
        return true;
    };
    headers
        .get(AUTHORIZATION)
        .and_then(|header| header.to_str().ok())
        .and_then(|header| header.strip_prefix("Bearer "))
        .is_some_and(|provided| provided.as_bytes().ct_eq(expected.as_bytes()).into())
}
