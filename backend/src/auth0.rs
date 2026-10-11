//! Auth0 access-token verification. The app and the admin page sign in with Auth0 (passwordless
//! email or Sign in with Apple), then trade the Auth0 access token for the backend's own
//! revocable session at `POST /api/accounts/auth0`. Nothing here is on the per-request path.
use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header, jwk::JwkSet};
use serde::Deserialize;
use serde_json::{Map, Value};
use tokio::sync::Mutex;

/// Access tokens carry a handful of claims; anything bigger is not one.
const MAX_TOKEN_BYTES: usize = 8 * 1024;
const JWKS_TTL: Duration = Duration::from_secs(600);
/// An unknown `kid` forces at most one refresh per interval, so a bad token can't hammer Auth0.
const FORCED_REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_NAMESPACE: &str = "https://inview.app/";
/// A token is traded for a session right after sign-in; older ones are not accepted, which
/// bounds how long a leaked ID or access token could be replayed.
const MAX_TOKEN_AGE_SECONDS: u64 = 600;

#[derive(Clone, Debug)]
pub struct Auth0Config {
    /// Tenant host, e.g. `tenant.us.auth0.com`; the issuer is `https://{domain}/`.
    pub domain: String,
    /// Optional API identifier. Without one, Auth0 issues the app an opaque access token, so the
    /// app trades its **ID token** (audience = its client ID) instead.
    pub api_audience: Option<String>,
    /// The native app's client ID, accepted as an ID-token audience.
    pub client_id: Option<String>,
    /// Prefix of the custom claims the post-login Action adds (`{ns}email`, `{ns}roles`, ...).
    pub namespace: String,
    /// Verified emails treated as administrators even without the role claim.
    pub admin_emails: Vec<String>,
    /// The SPA application the admin page signs in with (public identifier, not a secret).
    pub admin_client_id: Option<String>,
}

impl Auth0Config {
    pub fn issuer(&self) -> String {
        format!("https://{}/", self.domain)
    }
    /// Audiences a token may carry: the API identifier and the clients we sign in.
    pub fn audiences(&self) -> Vec<String> {
        [&self.api_audience, &self.client_id, &self.admin_client_id]
            .into_iter()
            .flatten()
            .cloned()
            .collect()
    }
    fn claim(&self, name: &str) -> String {
        format!("{}{name}", self.namespace)
    }
}

/// Who the token says is signing in. Only built from a token whose signature and claims verified.
#[derive(Clone, Debug, PartialEq)]
pub struct Identity {
    pub sub: String,
    pub email: String,
    pub email_verified: bool,
    pub name: Option<String>,
    pub roles: Vec<String>,
}

#[derive(Debug, PartialEq)]
pub enum VerifyError {
    /// The token is not acceptable: malformed, wrong issuer/audience, expired, unknown key...
    Invalid(&'static str),
    /// The key set could not be fetched; the token itself may be fine.
    Unavailable,
}

enum Source {
    Remote {
        url: String,
        client: reqwest::Client,
    },
    Static(JwkSet),
}

#[derive(Default)]
struct Cache {
    keys: Option<JwkSet>,
    fetched_at: Option<Instant>,
    forced_at: Option<Instant>,
}

pub struct Auth0 {
    config: Auth0Config,
    source: Source,
    cache: Mutex<Cache>,
}

#[derive(Deserialize)]
struct Claims {
    sub: String,
    #[serde(flatten)]
    extra: Map<String, Value>,
}

fn clean_domain(raw: &str) -> Result<String, String> {
    let domain = raw
        .trim()
        .trim_start_matches("https://")
        .trim_end_matches('/')
        .to_ascii_lowercase();
    let valid = !domain.is_empty()
        && domain.len() <= 253
        && domain.contains('.')
        && domain
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.');
    if valid {
        Ok(domain)
    } else {
        Err("INVIEW_AUTH0_DOMAIN must be a host name such as tenant.us.auth0.com".into())
    }
}

impl Auth0 {
    /// Reads `INVIEW_AUTH0_*`. Returns `Ok(None)` when no domain is set, which keeps the
    /// password-only behaviour; a partly configured tenant is a startup error.
    pub fn from_env() -> Result<Option<Self>, String> {
        let get = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
        let Some(domain) = get("INVIEW_AUTH0_DOMAIN") else {
            let stray = ["AUDIENCE", "CLIENT_ID", "ADMIN_CLIENT_ID"]
                .iter()
                .any(|name| get(&format!("INVIEW_AUTH0_{name}")).is_some());
            if stray {
                return Err("INVIEW_AUTH0_* settings require INVIEW_AUTH0_DOMAIN".into());
            }
            return Ok(None);
        };
        let api_audience = get("INVIEW_AUTH0_AUDIENCE").map(|v| v.trim().to_owned());
        let client_id = get("INVIEW_AUTH0_CLIENT_ID").map(|v| v.trim().to_owned());
        let admin_client_id = get("INVIEW_AUTH0_ADMIN_CLIENT_ID").map(|v| v.trim().to_owned());
        if api_audience.is_none() && client_id.is_none() && admin_client_id.is_none() {
            return Err("Set INVIEW_AUTH0_CLIENT_ID (the app's client ID) or INVIEW_AUTH0_AUDIENCE (an API identifier)".into());
        }
        let mut namespace =
            get("INVIEW_AUTH0_NAMESPACE").unwrap_or_else(|| DEFAULT_NAMESPACE.into());
        if !namespace.ends_with('/') {
            namespace.push('/');
        }
        let admin_emails = get("INVIEW_ADMIN_EMAILS")
            .map(|list| {
                list.split(',')
                    .map(|e| e.trim().to_ascii_lowercase())
                    .filter(|e| !e.is_empty())
                    .collect()
            })
            .unwrap_or_default();
        let config = Auth0Config {
            domain: clean_domain(&domain)?,
            api_audience,
            client_id,
            namespace,
            admin_emails,
            admin_client_id,
        };
        Ok(Some(Self::remote(config)))
    }

    fn remote(config: Auth0Config) -> Self {
        let client = reqwest::Client::builder()
            .timeout(FETCH_TIMEOUT)
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("HTTP client");
        let url = format!("https://{}/.well-known/jwks.json", config.domain);
        Self {
            config,
            source: Source::Remote { url, client },
            cache: Mutex::default(),
        }
    }

    /// A verifier over a fixed key set, for tests and offline use.
    pub fn with_static_jwks(config: Auth0Config, keys: JwkSet) -> Self {
        Self {
            config,
            source: Source::Static(keys),
            cache: Mutex::default(),
        }
    }

    pub fn config(&self) -> &Auth0Config {
        &self.config
    }

    /// Whether this identity may administer: the role claim, or a verified allowlisted email.
    pub fn is_admin(&self, identity: &Identity) -> bool {
        identity
            .roles
            .iter()
            .any(|r| r.eq_ignore_ascii_case("admin"))
            || (identity.email_verified
                && self
                    .config
                    .admin_emails
                    .contains(&identity.email.to_ascii_lowercase()))
    }

    async fn keys(&self, force: bool) -> Result<JwkSet, VerifyError> {
        if let Source::Static(keys) = &self.source {
            return Ok(keys.clone());
        }
        let mut cache = self.cache.lock().await;
        let fresh = cache.fetched_at.is_some_and(|t| t.elapsed() < JWKS_TTL);
        let may_force = cache
            .forced_at
            .is_none_or(|t| t.elapsed() >= FORCED_REFRESH_INTERVAL);
        if let (Some(keys), true) = (&cache.keys, fresh && !(force && may_force)) {
            return Ok(keys.clone());
        }
        if force {
            cache.forced_at = Some(Instant::now());
        }
        let Source::Remote { url, client } = &self.source else {
            unreachable!()
        };
        let fetched = async {
            let response = client.get(url).send().await.ok()?.error_for_status().ok()?;
            response.json::<JwkSet>().await.ok()
        }
        .await;
        match fetched {
            Some(keys) => {
                cache.keys = Some(keys.clone());
                cache.fetched_at = Some(Instant::now());
                Ok(keys)
            }
            // A stale key set beats refusing everyone while Auth0 blips.
            None => cache.keys.clone().ok_or(VerifyError::Unavailable),
        }
    }

    pub async fn verify(&self, token: &str) -> Result<Identity, VerifyError> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(VerifyError::Invalid("token size"));
        }
        let header = decode_header(token).map_err(|_| VerifyError::Invalid("malformed token"))?;
        // Never trust the token's own `alg`: Auth0 signs API tokens with RS256.
        if header.alg != Algorithm::RS256 {
            return Err(VerifyError::Invalid("unsupported algorithm"));
        }
        let kid = header.kid.ok_or(VerifyError::Invalid("missing key id"))?;
        let mut keys = self.keys(false).await?;
        if keys.find(&kid).is_none() {
            keys = self.keys(true).await?;
        }
        let jwk = keys
            .find(&kid)
            .ok_or(VerifyError::Invalid("unknown signing key"))?;
        let key =
            DecodingKey::from_jwk(jwk).map_err(|_| VerifyError::Invalid("unusable signing key"))?;

        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[self.config.issuer()]);
        validation.set_audience(&self.config.audiences());
        validation.set_required_spec_claims(&["exp", "iss", "aud", "sub", "iat"]);
        validation.validate_nbf = true;
        validation.leeway = 30;
        let claims = decode::<Claims>(token, &key, &validation)
            .map_err(|_| VerifyError::Invalid("claims or signature"))?
            .claims;

        let issued = claims
            .extra
            .get("iat")
            .and_then(Value::as_u64)
            .ok_or(VerifyError::Invalid("missing issue time"))?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if issued > now + 60 || now.saturating_sub(issued) > MAX_TOKEN_AGE_SECONDS {
            return Err(VerifyError::Invalid("token too old"));
        }
        let text = |name: &str| {
            claims
                .extra
                .get(&self.config.claim(name))
                .or_else(|| claims.extra.get(name))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        };
        let flag = |name: &str| {
            claims
                .extra
                .get(&self.config.claim(name))
                .or_else(|| claims.extra.get(name))
                .and_then(Value::as_bool)
        };
        let roles = claims
            .extra
            .get(&self.config.claim("roles"))
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        Ok(Identity {
            sub: claims.sub,
            email: text("email").ok_or(VerifyError::Invalid("missing email"))?,
            email_verified: flag("email_verified").unwrap_or(false),
            name: text("name"),
            roles,
        })
    }
}

pub type SharedAuth0 = Arc<Auth0>;
