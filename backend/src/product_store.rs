//! Durable account and reviewed-map records. Raw submissions and published releases are immutable.
use crate::error::ApiError;
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier, password_hash::SaltString};
use axum::http::StatusCode;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use fs2::FileExt;
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::Semaphore;
use uuid::Uuid;

pub const VENUE_ID: &str = "student-center-east";
const SESSION_SECONDS: u64 = 14 * 24 * 60 * 60;
/// Administrators sign in again daily; their rights come from Auth0 at each sign-in.
const ADMIN_SESSION_SECONDS: u64 = 8 * 60 * 60;
const MAX_DATABASE_BYTES: usize = 128 * 1024 * 1024;
static DUMMY_HASH: OnceLock<String> = OnceLock::new();

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    User,
    Admin,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Account {
    pub id: String,
    pub email: String,
    pub name: String,
    pub role: Role,
}
#[derive(Clone, Deserialize, Serialize)]
struct StoredAccount {
    account: Account,
    /// Absent for passwordless accounts that only sign in through Auth0.
    #[serde(default)]
    password_hash: Option<String>,
    /// The Auth0 subject (`apple|...`, `email|...`) linked to this account.
    #[serde(default)]
    auth0_sub: Option<String>,
    /// Only explicit bootstrap configuration grants break-glass password access. Legacy stores
    /// default to false; restarting with matching bootstrap credentials migrates that account.
    #[serde(default)]
    bootstrap_admin: bool,
    /// Whether other signed-in people may find this account. Off until the person turns it on.
    #[serde(default)]
    discoverable: bool,
    /// A name the person chose to be found by; unique, lower case.
    #[serde(default)]
    handle: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
struct Session {
    account_id: String,
    expires_at: u64,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SubmissionStatus {
    Submitted,
    InReview,
    ChangesRequested,
    Published,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct SourceRevision {
    pub revision: u64,
    pub received_at: u64,
    pub payload: Value,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct ReviewEvent {
    pub revision: u64,
    pub at: u64,
    pub actor_id: String,
    pub action: String,
    pub note: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Submission {
    pub id: String,
    pub owner_id: String,
    pub venue_id: String,
    pub floor: u8,
    pub title: String,
    pub notes: String,
    pub status: SubmissionStatus,
    pub revision: u64,
    pub created_at: u64,
    pub updated_at: u64,
    pub review_note: Option<String>,
    pub published_version: Option<u64>,
    pub original_map: Value,
    pub map: Value,
    pub sources: Vec<SourceRevision>,
    pub history: Vec<ReviewEvent>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct PublishedMap {
    pub id: String,
    pub submission_id: String,
    pub venue_id: String,
    pub floor: u8,
    pub version: u64,
    pub source_revision: u64,
    pub published_at: u64,
    pub published_by: String,
    pub map: Value,
    pub ar_ready: bool,
}
#[derive(Clone, Deserialize, Serialize)]
struct RetryRecord {
    submission_id: String,
    payload: Value,
}
#[derive(Clone, Deserialize, Serialize)]
struct Database {
    schema_version: u32,
    accounts: BTreeMap<String, StoredAccount>,
    sessions: BTreeMap<String, Session>,
    submissions: BTreeMap<String, Submission>,
    retries: BTreeMap<String, RetryRecord>,
    releases: Vec<PublishedMap>,
}
impl Default for Database {
    fn default() -> Self {
        Self {
            schema_version: 1,
            accounts: BTreeMap::new(),
            sessions: BTreeMap::new(),
            submissions: BTreeMap::new(),
            retries: BTreeMap::new(),
            releases: vec![],
        }
    }
}
struct Inner {
    root: PathBuf,
    data: Mutex<Database>,
    _lock: File,
    temporary: bool,
    dummy_hash: String,
    attempts: Mutex<BTreeMap<String, (u64, u8)>>,
}
impl Drop for Inner {
    fn drop(&mut self) {
        if self.temporary {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}
#[derive(Clone)]
pub struct ProductStore {
    inner: Arc<Inner>,
    pub(crate) auth_workers: Arc<Semaphore>,
}
impl Default for ProductStore {
    fn default() -> Self {
        let root = std::env::temp_dir().join(format!("inview-product-{}", Uuid::new_v4()));
        Self::open_inner(root, true).expect("temporary product store")
    }
}
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn storage_error(error: impl std::fmt::Display) -> ApiError {
    tracing::error!(%error,"Product storage failed");
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage_failed",
        "Your changes could not be saved. Try again.",
    )
}
pub fn unauthorized() -> ApiError {
    ApiError::new(
        StatusCode::UNAUTHORIZED,
        "unauthorized",
        "Sign in to continue.",
    )
}
pub fn forbidden() -> ApiError {
    ApiError::new(
        StatusCode::FORBIDDEN,
        "forbidden",
        "You do not have access to this action.",
    )
}
pub fn conflict() -> ApiError {
    ApiError::new(
        StatusCode::CONFLICT,
        "revision_conflict",
        "This submission changed. Reload it before continuing.",
    )
}
fn hash_password(password: &str) -> Result<String, ApiError> {
    Argon2::default()
        .hash_password(password.as_bytes(), &SaltString::generate(&mut OsRng))
        .map(|h| h.to_string())
        .map_err(storage_error)
}
fn digest_token(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

/// How a person can be found by other signed-in people. Everything is opt-in.
#[derive(Clone, Debug, Serialize)]
pub struct Discovery {
    pub discoverable: bool,
    pub handle: Option<String>,
    /// Whether someone typing this account's email can find it: only Auth0-verified addresses that
    /// are not Apple "Hide My Email" relays.
    pub email_searchable: bool,
}
/// What a lookup reveals about another person: a display name and the handle they chose. Never an
/// email, account id or sign-in method.
#[derive(Clone, Debug, Serialize)]
pub struct Person {
    pub person_id: String,
    pub name: String,
    pub handle: Option<String>,
}
const PRIVATE_RELAY_DOMAIN: &str = "privaterelay.appleid.com";
const LOOKUPS_PER_WINDOW: u8 = 30;
fn email_searchable(stored: &StoredAccount) -> bool {
    stored.auth0_sub.is_some()
        && !stored
            .account
            .email
            .ends_with(&format!("@{PRIVATE_RELAY_DOMAIN}"))
}
pub fn validate_handle(handle: &str) -> Result<String, ApiError> {
    let handle = handle.trim().trim_start_matches('@').to_ascii_lowercase();
    let valid = (3..=24).contains(&handle.len())
        && handle.starts_with(|c: char| c.is_ascii_alphanumeric())
        && handle
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.');
    if valid {
        Ok(handle)
    } else {
        Err(ApiError::invalid(
            "Use 3 to 24 letters, numbers, dots or underscores, starting with a letter or number.",
        ))
    }
}
const MAX_CONTACT_HASHES: usize = 500;
const CONTACT_MATCHES_PER_WINDOW: u8 = 10;
const CONTACT_HASH_PREFIX: &str = "inview-contacts-v1:";
/// The identifier an app sends for one contact email: lower-case hex SHA-256 of the prefix plus the
/// trimmed, lower-cased address. Apps compute the same value on the device, so no address leaves it.
pub fn contact_hash(email: &str) -> String {
    let digest = Sha256::digest(
        format!("{CONTACT_HASH_PREFIX}{}", email.trim().to_ascii_lowercase()).as_bytes(),
    );
    digest.iter().map(|b| format!("{b:02x}")).collect()
}
#[derive(Clone, Debug, Serialize)]
pub struct ContactMatch {
    /// The hash the app sent, so it can map the match back to the contact it came from.
    pub hash: String,
    #[serde(flatten)]
    pub person: Person,
}
fn person_of(stored: &StoredAccount) -> Person {
    // Passwordless email sign-in often names the account after its address; never expose that.
    let name = Some(stored.account.name.trim())
        .filter(|n| !n.is_empty() && !n.contains('@'))
        .map(str::to_owned)
        .or_else(|| stored.handle.clone())
        .unwrap_or_else(|| "InView user".to_owned());
    Person {
        person_id: person_id(&stored.account.id),
        name,
        handle: stored.handle.clone(),
    }
}
fn person_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "person_not_found",
        "No one with that email or handle is available to find.",
    )
}
fn person_id(account_id: &str) -> String {
    let digest = Sha256::digest(format!("inview-person:{account_id}").as_bytes());
    URL_SAFE_NO_PAD.encode(digest)[..22].to_owned()
}
pub fn validate_email(email: &str) -> Result<String, ApiError> {
    let email = email.trim().to_ascii_lowercase();
    let parts: Vec<_> = email.split('@').collect();
    if email.len() > 254
        || parts.len() != 2
        || parts[0].is_empty()
        || !parts[1].contains('.')
        || parts[1].starts_with('.')
        || parts[1].ends_with('.')
        || email
            .bytes()
            .any(|c| c.is_ascii_whitespace() || c.is_ascii_control())
    {
        return Err(ApiError::invalid("Enter a valid email address."));
    }
    Ok(email)
}
pub fn validate_password(password: &str) -> Result<(), ApiError> {
    if password.chars().count() < 12 || password.len() > 1024 {
        return Err(ApiError::invalid(
            "Use a password with at least 12 characters.",
        ));
    }
    Ok(())
}
#[derive(Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub expires_at: u64,
    pub account: Account,
}
impl ProductStore {
    pub fn open(root: impl AsRef<Path>) -> io::Result<Self> {
        Self::open_inner(root.as_ref().to_path_buf(), false)
    }
    fn open_inner(root: PathBuf, temporary: bool) -> io::Result<Self> {
        fs::create_dir_all(&root)?;
        if fs::symlink_metadata(&root)?.file_type().is_symlink() {
            return Err(io::Error::other("Product directory must not be a symlink"));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;
        }
        let lock_path = root.join("store.lock");
        reject_symlink(&lock_path)?;
        let lock = private_file(&lock_path, false)?;
        lock.try_lock_exclusive()
            .map_err(|_| io::Error::other("Product directory is already in use"))?;
        let path = root.join("product.json");
        reject_symlink(&path)?;
        let data = if path.exists() {
            if fs::metadata(&path)?.len() > MAX_DATABASE_BYTES as u64 {
                return Err(io::Error::other("Product database exceeds its size limit"));
            }
            serde_json::from_slice::<Database>(&fs::read(path)?).map_err(io::Error::other)?
        } else {
            Database::default()
        };
        if data.schema_version != 1 {
            return Err(io::Error::other("Unsupported product database version"));
        }
        let dummy_hash = DUMMY_HASH
            .get_or_init(|| {
                hash_password("inview-unassigned-password-sentinel")
                    .expect("Password hashing supported")
            })
            .clone();
        Ok(Self {
            inner: Arc::new(Inner {
                root,
                data: Mutex::new(data),
                _lock: lock,
                temporary,
                dummy_hash,
                attempts: Mutex::new(BTreeMap::new()),
            }),
            auth_workers: Arc::new(Semaphore::new(2)),
        })
    }
    fn transaction<T>(
        &self,
        change: impl FnOnce(&mut Database) -> Result<T, ApiError>,
    ) -> Result<T, ApiError> {
        let mut current = self.inner.data.lock().map_err(storage_error)?;
        let mut next = current.clone();
        let result = change(&mut next)?;
        next.sessions
            .retain(|_, session| session.expires_at > now());
        let bytes = serde_json::to_vec(&next).map_err(storage_error)?;
        if bytes.len() > MAX_DATABASE_BYTES {
            return Err(ApiError::new(
                StatusCode::INSUFFICIENT_STORAGE,
                "storage_full",
                "The submission store is full. Contact an administrator.",
            ));
        }
        let temp = self.inner.root.join(format!(".write-{}", Uuid::new_v4()));
        let write = (|| -> io::Result<()> {
            let mut file = private_file(&temp, true)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temp, self.inner.root.join("product.json"))?;
            File::open(&self.inner.root)?.sync_all()?;
            Ok(())
        })();
        if let Err(error) = write {
            let _ = fs::remove_file(&temp);
            return Err(storage_error(error));
        }
        *current = next;
        Ok(result)
    }
    pub fn bootstrap_admin(&self, email: &str, password: &str) -> Result<(), ApiError> {
        let email = validate_email(email)?;
        validate_password(password)?;
        let password_hash = hash_password(password)?;
        self.transaction(|db| {
            if let Some(stored) = db.accounts.get_mut(&email) {
                if stored.account.role != Role::Admin {
                    return Err(ApiError::new(StatusCode::CONFLICT, "admin_conflict",
                        "Bootstrap email is already a contributor account. Choose a dedicated administrator email."));
                }
                let matches = stored.password_hash.as_deref()
                    .and_then(|hash| PasswordHash::new(hash).ok())
                    .is_some_and(|hash| Argon2::default().verify_password(password.as_bytes(), &hash).is_ok());
                if !matches {
                    return Err(ApiError::new(StatusCode::CONFLICT, "admin_conflict",
                        "Bootstrap administrator has no matching password. Supply its existing bootstrap password or choose a dedicated administrator email; credentials were not changed."));
                }
                if !stored.bootstrap_admin {
                    stored.bootstrap_admin = true;
                    let id = stored.account.id.clone();
                    db.sessions.retain(|_, session| session.account_id != id);
                }
                return Ok(());
            }
            let account = Account { id: Uuid::new_v4().to_string(), email: email.clone(), name: "Administrator".into(), role: Role::Admin };
            db.accounts.insert(email, StoredAccount { account, password_hash: Some(password_hash), auth0_sub: None, bootstrap_admin: true, discoverable: false, handle: None });
            Ok(())
        })
    }
    pub fn register(
        &self,
        email: &str,
        password: &str,
        name: Option<&str>,
    ) -> Result<AuthResponse, ApiError> {
        let email = validate_email(email)?;
        validate_password(password)?;
        self.attempt("register", 10)?;
        let name = name
            .unwrap_or_else(|| email.split('@').next().unwrap_or("User"))
            .trim();
        if name.is_empty() || name.chars().count() > 80 {
            return Err(ApiError::invalid("Use a name with 1 to 80 characters."));
        }
        let stored = StoredAccount {
            account: Account {
                id: Uuid::new_v4().to_string(),
                email: email.clone(),
                name: name.into(),
                role: Role::User,
            },
            password_hash: Some(hash_password(password)?),
            auth0_sub: None,
            bootstrap_admin: false,
            discoverable: false,
            handle: None,
        };
        self.transaction(|db| {
            if db.accounts.contains_key(&email) {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "account_exists",
                    "An account already uses this email. Sign in instead.",
                ));
            }
            if db.accounts.len() >= 10000 {
                return Err(ApiError::new(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "accounts_full",
                    "New accounts are temporarily unavailable.",
                ));
            }
            db.accounts.insert(email, stored.clone());
            create_session(db, stored.account)
        })
    }
    pub fn login(&self, email: &str, password: &str) -> Result<AuthResponse, ApiError> {
        self.login_with(email, password, false)
    }
    /// `admin_only` is the break-glass mode used once Auth0 is the sign-in for everyone else.
    pub fn login_with(
        &self,
        email: &str,
        password: &str,
        admin_only: bool,
    ) -> Result<AuthResponse, ApiError> {
        let email = validate_email(email)?;
        if password.len() > 1024 {
            return Err(unauthorized());
        }
        self.attempt(&email, 10)?;
        let stored = self
            .inner
            .data
            .lock()
            .map_err(storage_error)?
            .accounts
            .get(&email)
            .cloned();
        let hash = stored
            .as_ref()
            .and_then(|s| s.password_hash.as_deref())
            .unwrap_or(&self.inner.dummy_hash);
        let parsed = PasswordHash::new(hash).map_err(storage_error)?;
        let verified = Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok();
        let stored = stored
            .filter(|s| verified && s.password_hash.is_some())
            .filter(|s| !admin_only || (s.bootstrap_admin && s.account.role == Role::Admin))
            .ok_or_else(|| {
                ApiError::new(
                    StatusCode::UNAUTHORIZED,
                    "invalid_credentials",
                    "Email or password is incorrect.",
                )
            })?;
        self.transaction(|db| {
            // Password verification runs outside the database lock. A concurrent identity binding
            // or role change must not allow that earlier authentication to mint a new session.
            let current = db.accounts.get(&email).ok_or_else(unauthorized)?;
            if current.password_hash != stored.password_hash
                || current.auth0_sub != stored.auth0_sub
                || current.bootstrap_admin != stored.bootstrap_admin
                || current.account.role != stored.account.role
            {
                return Err(unauthorized());
            }
            create_session(db, stored.account)
        })
    }
    /// Signs in a verified Auth0 identity, creating or linking the account.
    ///
    /// Accounts are keyed by email, so only a **verified** email may link to an existing account
    /// (keeping its id and submissions). `admin` comes from the token's claims at this sign-in and
    /// is re-derived every time, so removing the role in Auth0 demotes on the next sign-in; the
    /// password-bootstrapped administrator is kept as break-glass.
    pub fn sign_in_external(
        &self,
        sub: &str,
        email: &str,
        name: Option<&str>,
        admin: bool,
    ) -> Result<AuthResponse, ApiError> {
        let email = validate_email(email)?;
        if sub.is_empty() || sub.len() > 256 {
            return Err(unauthorized());
        }
        self.attempt(&format!("auth0:{sub}"), 30)?;
        self.transaction(|db| {
            let key = db
                .accounts
                .iter()
                .find(|(_, a)| a.auth0_sub.as_deref() == Some(sub))
                .map(|(k, _)| k.clone())
                .or_else(|| db.accounts.contains_key(&email).then(|| email.clone()));
            let ttl;
            let account = if let Some(key) = key {
                let stored = db.accounts.get_mut(&key).expect("key came from the map");
                let first_binding = stored.auth0_sub.is_none();
                let previous_role = stored.account.role.clone();
                match stored.auth0_sub.as_deref() {
                    Some(linked) if linked != sub => {
                        return Err(ApiError::new(
                            StatusCode::CONFLICT,
                            "account_linked",
                            "This email already belongs to a different sign-in.",
                        ));
                    }
                    _ => stored.auth0_sub = Some(sub.to_owned()),
                }
                stored.account.role = if admin || stored.bootstrap_admin {
                    Role::Admin
                } else {
                    Role::User
                };
                ttl = if stored.account.role == Role::Admin {
                    ADMIN_SESSION_SECONDS
                } else {
                    SESSION_SECONDS
                };
                let account = stored.account.clone();
                if first_binding || (previous_role != Role::Admin && account.role == Role::Admin) {
                    db.sessions
                        .retain(|_, session| session.account_id != account.id);
                }
                account
            } else {
                if db.accounts.len() >= 10000 {
                    return Err(ApiError::new(
                        StatusCode::SERVICE_UNAVAILABLE,
                        "accounts_full",
                        "New accounts are temporarily unavailable.",
                    ));
                }
                let display = name
                    .map(str::trim)
                    .filter(|n| !n.is_empty() && n.chars().count() <= 80)
                    .map(str::to_owned)
                    .unwrap_or_else(|| email.split('@').next().unwrap_or("User").to_owned());
                let account = Account {
                    id: Uuid::new_v4().to_string(),
                    email: email.clone(),
                    name: display,
                    role: if admin { Role::Admin } else { Role::User },
                };
                ttl = if admin {
                    ADMIN_SESSION_SECONDS
                } else {
                    SESSION_SECONDS
                };
                db.accounts.insert(
                    email.clone(),
                    StoredAccount {
                        account: account.clone(),
                        password_hash: None,
                        auth0_sub: Some(sub.to_owned()),
                        bootstrap_admin: false,
                        discoverable: false,
                        handle: None,
                    },
                );
                account
            };
            create_session_for(db, account, ttl)
        })
    }
    fn attempt(&self, key: &str, limit: u8) -> Result<(), ApiError> {
        let mut attempts = self.inner.attempts.lock().map_err(storage_error)?;
        let time = now();
        attempts.retain(|_, (start, _)| time.saturating_sub(*start) < 900);
        if attempts.len() >= 10000 && !attempts.contains_key(key) {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "auth_rate_limited",
                "Too many sign-in attempts. Try again later.",
            ));
        }
        let record = attempts.entry(key.to_string()).or_insert((time, 0));
        if record.1 >= limit {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "auth_rate_limited",
                "Too many sign-in attempts. Try again in 15 minutes.",
            ));
        }
        record.1 += 1;
        Ok(())
    }
    fn stored_by_id<'a>(db: &'a Database, id: &str) -> Option<&'a StoredAccount> {
        db.accounts.values().find(|a| a.account.id == id)
    }
    pub fn discovery(&self, account: &Account) -> Result<Discovery, ApiError> {
        let db = self.inner.data.lock().map_err(storage_error)?;
        let stored = Self::stored_by_id(&db, &account.id).ok_or_else(unauthorized)?;
        Ok(Discovery {
            discoverable: stored.discoverable,
            handle: stored.handle.clone(),
            email_searchable: email_searchable(stored),
        })
    }
    /// `handle`: `None` leaves it as is, `Some(None)` clears it, `Some(Some(h))` sets it.
    pub fn set_discovery(
        &self,
        account: &Account,
        discoverable: Option<bool>,
        handle: Option<Option<String>>,
    ) -> Result<Discovery, ApiError> {
        let handle = match handle {
            Some(Some(raw)) => Some(Some(validate_handle(&raw)?)),
            other => other.map(|_| None),
        };
        self.transaction(|db| {
            if let Some(Some(wanted)) = &handle
                && db
                    .accounts
                    .values()
                    .any(|a| a.account.id != account.id && a.handle.as_deref() == Some(wanted))
            {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "handle_taken",
                    "That handle is already in use.",
                ));
            }
            let stored = db
                .accounts
                .values_mut()
                .find(|a| a.account.id == account.id)
                .ok_or_else(unauthorized)?;
            if let Some(value) = discoverable {
                stored.discoverable = value;
            }
            if let Some(value) = handle {
                stored.handle = value;
            }
            Ok(Discovery {
                discoverable: stored.discoverable,
                handle: stored.handle.clone(),
                email_searchable: email_searchable(stored),
            })
        })
    }
    /// Finds one person by exact verified email or exact handle. Not-found, not-discoverable, a
    /// relay address and yourself all look the same, and lookups are rate limited per searcher, so
    /// the directory cannot be browsed or probed for who has an account.
    pub fn find_person(&self, searcher: &Account, query: &str) -> Result<Person, ApiError> {
        self.attempt(&format!("lookup:{}", searcher.id), LOOKUPS_PER_WINDOW)?;
        let query = query.trim();
        let db = self.inner.data.lock().map_err(storage_error)?;
        let (found, by_email) = if query.contains('@') && !query.starts_with('@') {
            let email = validate_email(query).map_err(|_| person_not_found())?;
            (db.accounts.get(&email), true)
        } else {
            let handle = validate_handle(query).map_err(|_| person_not_found())?;
            (
                db.accounts
                    .values()
                    .find(|a| a.handle.as_deref() == Some(handle.as_str())),
                false,
            )
        };
        let stored = found
            .filter(|a| a.discoverable && a.account.id != searcher.id)
            .filter(|a| !by_email || email_searchable(a))
            .ok_or_else(person_not_found)?;
        Ok(person_of(stored))
    }
    /// Matches an address book against opted-in people. The app sends SHA-256 hashes of its contacts'
    /// normalised emails (see [`contact_hash`]); only discoverable accounts with a searchable email can
    /// match, so a contact who never opted in is indistinguishable from a stranger. Uploaded hashes
    /// are not stored.
    pub fn match_contacts(
        &self,
        searcher: &Account,
        hashes: &[String],
    ) -> Result<Vec<ContactMatch>, ApiError> {
        if hashes.len() > MAX_CONTACT_HASHES {
            return Err(ApiError::invalid("Send at most 500 contacts at a time."));
        }
        if hashes.iter().any(|h| {
            h.len() != 64
                || !h
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        }) {
            return Err(ApiError::invalid(
                "Contacts must be lower-case SHA-256 hex digests.",
            ));
        }
        self.attempt(
            &format!("contacts:{}", searcher.id),
            CONTACT_MATCHES_PER_WINDOW,
        )?;
        let wanted: std::collections::HashSet<&str> = hashes.iter().map(String::as_str).collect();
        let db = self.inner.data.lock().map_err(storage_error)?;
        let mut matches: Vec<ContactMatch> = db
            .accounts
            .values()
            .filter(|a| a.discoverable && a.account.id != searcher.id && email_searchable(a))
            .filter_map(|a| {
                let hash = contact_hash(&a.account.email);
                wanted.contains(hash.as_str()).then(|| ContactMatch {
                    hash,
                    person: person_of(a),
                })
            })
            .collect();
        matches.sort_by(|a, b| a.hash.cmp(&b.hash));
        Ok(matches)
    }
    pub fn account(&self, token: &str) -> Result<Account, ApiError> {
        if token.len() != 43 {
            return Err(unauthorized());
        }
        let db = self.inner.data.lock().map_err(storage_error)?;
        let session = db
            .sessions
            .get(&digest_token(token))
            .filter(|s| s.expires_at > now())
            .ok_or_else(unauthorized)?;
        db.accounts
            .values()
            .find(|a| a.account.id == session.account_id)
            .map(|a| a.account.clone())
            .ok_or_else(unauthorized)
    }
    pub fn logout(&self, token: &str) -> Result<(), ApiError> {
        self.account(token)?;
        self.transaction(|db| {
            db.sessions.remove(&digest_token(token));
            Ok(())
        })
    }
    pub fn list(&self, account: &Account, admin: bool) -> Result<Vec<Submission>, ApiError> {
        if admin && account.role != Role::Admin {
            return Err(forbidden());
        }
        let mut list: Vec<_> = self
            .inner
            .data
            .lock()
            .map_err(storage_error)?
            .submissions
            .values()
            .filter(|s| admin || s.owner_id == account.id)
            .cloned()
            .collect();
        list.sort_by(|a, b| b.updated_at.cmp(&a.updated_at).then(a.id.cmp(&b.id)));
        Ok(list)
    }
    pub fn get(&self, account: &Account, id: &str) -> Result<Submission, ApiError> {
        self.inner
            .data
            .lock()
            .map_err(storage_error)?
            .submissions
            .get(id)
            .filter(|s| s.owner_id == account.id || account.role == Role::Admin)
            .cloned()
            .ok_or_else(missing)
    }
    pub fn submit(
        &self,
        account: &Account,
        payload: Value,
    ) -> Result<(bool, Submission), ApiError> {
        let request: SubmitRequest = serde_json::from_value(payload.clone())
            .map_err(|_| ApiError::invalid("This submission could not be read."))?;
        request.validate()?;
        let key = format!("{}:{}", account.id, request.client_submission_id);
        self.transaction(|db| {
            if let Some(retry)=db.retries.get(&key) {
                if retry.payload!=payload { return Err(ApiError::new(StatusCode::CONFLICT,"submission_conflict","This saved upload contains different content. Use a new upload identifier.")); }
                return Ok((false,db.submissions[&retry.submission_id].clone()));
            }
            if db.submissions.len()>=10000 || db.submissions.values().filter(|s|s.owner_id==account.id).count()>=100 { return Err(ApiError::new(StatusCode::TOO_MANY_REQUESTS,"submission_limit","You have reached the submission limit. Contact an administrator.")); }
            let time=now(); let id=Uuid::new_v4().to_string();
            let submission=Submission{id:id.clone(),owner_id:account.id.clone(),venue_id:request.venue_id,floor:request.floor,title:request.title.unwrap_or_else(||format!("Floor {} scan",request.floor)),notes:request.notes.unwrap_or_default(),status:SubmissionStatus::Submitted,revision:1,created_at:time,updated_at:time,review_note:None,published_version:None,original_map:request.map.clone(),map:request.map,sources:vec![SourceRevision{revision:1,received_at:time,payload:payload.clone()}],history:vec![]};
            db.submissions.insert(id.clone(),submission.clone()); db.retries.insert(key,RetryRecord{submission_id:id,payload}); Ok((true,submission))
        })
    }
    pub fn resubmit(
        &self,
        account: &Account,
        id: &str,
        payload: Value,
    ) -> Result<(bool, Submission), ApiError> {
        let request: ResubmitRequest = serde_json::from_value(payload.clone())
            .map_err(|_| ApiError::invalid("This submission could not be read."))?;
        check_client_id(&request.client_submission_id)?;
        validate_map(&request.map)?;
        check_permission(request.authorized_space)?;
        check_text(request.notes.as_deref(), 2000, "Notes")?;
        let key = format!("{}:{}", account.id, request.client_submission_id);
        self.transaction(|db| {
            if let Some(retry) = db.retries.get(&key) {
                if retry.payload != payload || retry.submission_id != id {
                    return Err(conflict());
                }
                return Ok((false, db.submissions[id].clone()));
            }
            let submission = db
                .submissions
                .get_mut(id)
                .filter(|s| s.owner_id == account.id)
                .ok_or_else(missing)?;
            if submission.revision != request.expected_revision {
                return Err(conflict());
            }
            if submission.status != SubmissionStatus::ChangesRequested {
                return Err(ApiError::new(
                    StatusCode::CONFLICT,
                    "resubmit_unavailable",
                    "A revised scan can be uploaded after changes are requested.",
                ));
            }
            if submission.sources.len() >= 20 {
                return Err(ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS,
                    "revision_limit",
                    "This submission has reached its revision limit.",
                ));
            }
            submission.revision += 1;
            submission.map = request.map;
            submission.notes = request.notes.unwrap_or_default();
            submission.status = SubmissionStatus::Submitted;
            submission.updated_at = now();
            submission.review_note = None;
            submission.sources.push(SourceRevision {
                revision: submission.revision,
                received_at: now(),
                payload: payload.clone(),
            });
            let result = submission.clone();
            db.retries.insert(
                key,
                RetryRecord {
                    submission_id: id.into(),
                    payload,
                },
            );
            Ok((true, result))
        })
    }
    pub fn edit(
        &self,
        account: &Account,
        id: &str,
        request: EditRequest,
    ) -> Result<Submission, ApiError> {
        if account.role != Role::Admin {
            return Err(forbidden());
        }
        if let Some(map) = &request.map {
            validate_map(map)?;
        }
        check_text(request.review_note.as_deref(), 2000, "Review note")?;
        if let Some(status) = &request.status
            && !matches!(
                status,
                SubmissionStatus::InReview | SubmissionStatus::ChangesRequested
            )
        {
            return Err(ApiError::invalid(
                "Use in_review or changes_requested. Publish a map through its review action.",
            ));
        }
        if request.status == Some(SubmissionStatus::ChangesRequested)
            && request
                .review_note
                .as_ref()
                .is_none_or(|s| s.trim().is_empty())
        {
            return Err(ApiError::invalid(
                "Add a note explaining the requested changes.",
            ));
        }
        self.transaction(|db| {
            let submission = db.submissions.get_mut(id).ok_or_else(missing)?;
            if submission.revision != request.expected_revision {
                return Err(conflict());
            }
            if submission.history.len() >= 200 {
                return Err(ApiError::invalid(
                    "This submission has reached its edit limit.",
                ));
            }
            if let Some(map) = request.map {
                submission.map = map;
            }
            if let Some(note) = request.review_note {
                submission.review_note = Some(note);
            }
            submission.status = request.status.unwrap_or(SubmissionStatus::InReview);
            submission.revision += 1;
            submission.updated_at = now();
            submission.history.push(ReviewEvent {
                revision: submission.revision,
                at: now(),
                actor_id: account.id.clone(),
                action: "edited".into(),
                note: submission.review_note.clone(),
            });
            Ok(submission.clone())
        })
    }
    pub fn publish(
        &self,
        account: &Account,
        id: &str,
        request: PublishRequest,
    ) -> Result<PublishedMap, ApiError> {
        if account.role != Role::Admin {
            return Err(forbidden());
        }
        if !request.geometry_reviewed || !request.routes_reviewed || !request.floor_links_reviewed {
            return Err(ApiError::invalid(
                "Check the map, routes and floor links before publishing.",
            ));
        }
        self.transaction(|db| {
            let submission = db.submissions.get(id).ok_or_else(missing)?;
            if submission.revision != request.expected_revision {
                return Err(conflict());
            }
            if submission.status == SubmissionStatus::ChangesRequested {
                return Err(ApiError::invalid(
                    "Wait for a revised scan before publishing.",
                ));
            }
            if let Some(release) = db
                .releases
                .iter()
                .find(|r| r.submission_id == id && r.source_revision == request.expected_revision)
            {
                return Ok(release.clone());
            }
            validate_map(&submission.map)?;
            let version = db
                .releases
                .iter()
                .filter(|r| r.floor == submission.floor)
                .map(|r| r.version)
                .max()
                .unwrap_or(0)
                + 1;
            let release = PublishedMap {
                id: Uuid::new_v4().to_string(),
                submission_id: id.into(),
                venue_id: VENUE_ID.into(),
                floor: submission.floor,
                version,
                source_revision: submission.revision,
                published_at: now(),
                published_by: account.id.clone(),
                map: submission.map.clone(),
                ar_ready: false,
            };
            db.releases.push(release.clone());
            let submission = db.submissions.get_mut(id).unwrap();
            submission.status = SubmissionStatus::Published;
            submission.published_version = Some(version);
            submission.updated_at = now();
            submission.history.push(ReviewEvent {
                revision: submission.revision,
                at: now(),
                actor_id: account.id.clone(),
                action: "published".into(),
                note: None,
            });
            Ok(release)
        })
    }
    pub fn published(&self) -> Result<Vec<PublishedMap>, ApiError> {
        let db = self.inner.data.lock().map_err(storage_error)?;
        let mut latest = BTreeMap::new();
        for release in &db.releases {
            latest.insert(release.floor, release.clone());
        }
        Ok(latest.into_values().collect())
    }
    pub fn version(&self, floor: u8, version: u64) -> Result<PublishedMap, ApiError> {
        self.inner
            .data
            .lock()
            .map_err(storage_error)?
            .releases
            .iter()
            .find(|r| r.floor == floor && r.version == version)
            .cloned()
            .ok_or_else(missing)
    }
}
fn create_session(db: &mut Database, account: Account) -> Result<AuthResponse, ApiError> {
    let ttl = if account.role == Role::Admin {
        ADMIN_SESSION_SECONDS
    } else {
        SESSION_SECONDS
    };
    create_session_for(db, account, ttl)
}
fn create_session_for(
    db: &mut Database,
    account: Account,
    ttl_seconds: u64,
) -> Result<AuthResponse, ApiError> {
    let mut bytes = [0; 32];
    OsRng.fill_bytes(&mut bytes);
    let token = URL_SAFE_NO_PAD.encode(bytes);
    let expires_at = now() + ttl_seconds;
    let mut existing: Vec<_> = db
        .sessions
        .iter()
        .filter(|(_, s)| s.account_id == account.id)
        .map(|(k, s)| (k.clone(), s.expires_at))
        .collect();
    existing.sort_by_key(|(_, expiry)| *expiry);
    for (key, _) in existing.iter().take(existing.len().saturating_sub(11)) {
        db.sessions.remove(key);
    }
    db.sessions.insert(
        digest_token(&token),
        Session {
            account_id: account.id.clone(),
            expires_at,
        },
    );
    Ok(AuthResponse {
        token,
        expires_at,
        account,
    })
}
fn missing() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "submission_not_found",
        "This submission is not available.",
    )
}
fn reject_symlink(path: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(m) if !m.is_file() => Err(io::Error::other("Product files must be regular files")),
        Ok(_) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
fn private_file(path: &Path, new: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    if new {
        options.create_new(true);
    } else {
        options.create(true).truncate(false);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SubmitRequest {
    pub client_submission_id: String,
    pub venue_id: String,
    pub floor: u8,
    pub map: Value,
    pub title: Option<String>,
    pub notes: Option<String>,
    pub authorized_space: bool,
}
impl SubmitRequest {
    fn validate(&self) -> Result<(), ApiError> {
        check_client_id(&self.client_submission_id)?;
        if self.venue_id != VENUE_ID || !(1..=3).contains(&self.floor) {
            return Err(ApiError::invalid(
                "Contributions are currently limited to Student Center East, Floors 1–3.",
            ));
        }
        check_permission(self.authorized_space)?;
        check_text(self.title.as_deref(), 120, "Title")?;
        check_text(self.notes.as_deref(), 2000, "Notes")?;
        validate_map(&self.map)
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResubmitRequest {
    pub client_submission_id: String,
    pub expected_revision: u64,
    pub map: Value,
    pub notes: Option<String>,
    pub authorized_space: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditRequest {
    pub expected_revision: u64,
    pub map: Option<Value>,
    pub review_note: Option<String>,
    pub status: Option<SubmissionStatus>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublishRequest {
    pub expected_revision: u64,
    pub geometry_reviewed: bool,
    pub routes_reviewed: bool,
    pub floor_links_reviewed: bool,
}
fn check_permission(confirmed: bool) -> Result<(), ApiError> {
    if !confirmed {
        return Err(ApiError::invalid(
            "Confirm you have permission to scan and share this space.",
        ));
    }
    Ok(())
}
fn check_client_id(id: &str) -> Result<(), ApiError> {
    if id.len() != 36 || ![8, 13, 18, 23].iter().all(|i| id.as_bytes()[*i] == b'-') {
        return Err(ApiError::invalid("Use a valid upload identifier."));
    }
    Uuid::parse_str(id)
        .map(|_| ())
        .map_err(|_| ApiError::invalid("Use a valid upload identifier."))
}
fn check_text(value: Option<&str>, max: usize, name: &str) -> Result<(), ApiError> {
    if value.is_some_and(|s| s.chars().count() > max || s.chars().any(|c| c == '\0')) {
        return Err(ApiError::invalid(format!("{name} is too long.")));
    }
    Ok(())
}

pub fn validate_map(map: &Value) -> Result<(), ApiError> {
    let invalid = || ApiError::invalid("The map contains incomplete or invalid geometry.");
    let object = map.as_object().ok_or_else(invalid)?;
    if object.keys().any(|k| {
        !matches!(
            k.as_str(),
            "createdAt"
                | "floorY"
                | "footprints"
                | "points"
                | "geographicReference"
                | "requiresMeasuredFloorCoverage"
                | "requiresOptimizedLocalization"
        )
    }) {
        return Err(ApiError::invalid("This map format is not supported."));
    }
    number(object.get("floorY"), 1000.)?;
    let date = object
        .get("createdAt")
        .and_then(Value::as_str)
        .filter(|s| s.len() <= 35 && !s.contains('.'))
        .ok_or_else(|| ApiError::invalid("Use an ISO 8601 capture date."))?;
    chrono::DateTime::parse_from_rfc3339(date)
        .map_err(|_| ApiError::invalid("Use an ISO 8601 capture date."))?;
    let footprints = object
        .get("footprints")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty() && a.len() <= 10000)
        .ok_or_else(invalid)?;
    let points = object
        .get("points")
        .and_then(Value::as_array)
        .filter(|a| a.len() <= 1000)
        .ok_or_else(invalid)?;
    let mut ids = std::collections::HashSet::new();
    let mut lower = [f32::INFINITY; 2];
    let mut upper = [f32::NEG_INFINITY; 2];
    let mut include = |point: [f32; 2]| -> Result<(), ApiError> {
        for axis in 0..2 {
            if !point[axis].is_finite() || point[axis].abs() > 10000. {
                return Err(invalid());
            }
            lower[axis] = lower[axis].min(point[axis]);
            upper[axis] = upper[axis].max(point[axis]);
            if upper[axis] - lower[axis] > 500. {
                return Err(ApiError::invalid(
                    "Keep each floor map within a 500-meter span.",
                ));
            }
        }
        Ok(())
    };
    for shape in footprints {
        let shape = shape.as_object().ok_or_else(invalid)?;
        if let Some(id) = shape.get("id").filter(|v| !v.is_null()) {
            let id = id.as_str().ok_or_else(invalid)?;
            check_client_id(id)?;
            let id = Uuid::parse_str(id).map_err(|_| invalid())?;
            if !ids.insert(id) {
                return Err(ApiError::invalid(
                    "Each map feature needs a unique identifier.",
                ));
            }
        }
        if !shape.get("kind").and_then(Value::as_str).is_some_and(|s| {
            matches!(
                s,
                "wall" | "obstacle" | "stairs" | "door" | "opening" | "window" | "floor"
            )
        }) {
            return Err(invalid());
        }
        let center = vector(shape.get("center"), 2, 10000.)?;
        let size = vector(shape.get("size"), 2, 500.)?;
        number(shape.get("yaw"), 100000.)?;
        if shape["size"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v.as_f64().unwrap() <= 0.)
        {
            return Err(invalid());
        }
        for key in ["bottom", "height"] {
            if let Some(value) = shape.get(key).filter(|v| !v.is_null()) {
                number(Some(value), 1000.)?;
                if key == "height" && value.as_f64().unwrap() < 0. {
                    return Err(invalid());
                }
            }
        }
        if let Some(furniture) = shape.get("furniture").filter(|v| !v.is_null())
            && !furniture.as_str().is_some_and(|s| {
                matches!(
                    s,
                    "table"
                        | "chair"
                        | "sofa"
                        | "bed"
                        | "storage"
                        | "appliance"
                        | "sink"
                        | "toilet"
                        | "bathtub"
                        | "television"
                        | "fireplace"
                )
            })
        {
            return Err(ApiError::invalid("This furniture type is not supported."));
        }
        if let Some(polygon) = shape.get("polygon").filter(|v| !v.is_null()) {
            let polygon = polygon
                .as_array()
                .filter(|a| (3..=128).contains(&a.len()))
                .ok_or_else(invalid)?;
            let mut outline = vec![];
            for point in polygon {
                let values = vector(Some(point), 2, 10000.)?;
                let point = [values[0] as f32, values[1] as f32];
                include(point)?;
                outline.push(point);
            }
            let origin = outline[0];
            let mut doubled_area = 0.;
            for index in 0..outline.len() {
                let a = outline[index];
                let b = outline[(index + 1) % outline.len()];
                let ax = (a[0] - origin[0]) as f64;
                let az = (a[1] - origin[1]) as f64;
                let bx = (b[0] - origin[0]) as f64;
                let bz = (b[1] - origin[1]) as f64;
                doubled_area += ax * bz - bx * az;
            }
            if doubled_area.abs() <= 0.000001 {
                return Err(ApiError::invalid(
                    "The floor outline needs a measurable area.",
                ));
            }
        } else {
            let yaw = shape["yaw"].as_f64().unwrap() as f32;
            let cosine = yaw.cos();
            let sine = yaw.sin();
            for (x, z) in [(-1., -1.), (1., -1.), (1., 1.), (-1., 1.)] {
                let x = x * size[0] as f32 / 2.;
                let z = z * size[1] as f32 / 2.;
                include([
                    center[0] as f32 + x * cosine - z * sine,
                    center[1] as f32 + x * sine + z * cosine,
                ])?;
            }
        }
    }
    for point in points {
        let point = point.as_object().ok_or_else(invalid)?;
        let id = point
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(invalid)?;
        check_client_id(id)?;
        let id = Uuid::parse_str(id).map_err(|_| invalid())?;
        if !ids.insert(id) {
            return Err(invalid());
        }
        if !point
            .get("kind")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "elevator" | "ramp" | "destination"))
        {
            return Err(invalid());
        }
        let position = vector(point.get("position"), 3, 10000.)?;
        if position[1].abs() > 1000. {
            return Err(invalid());
        }
        include([position[0] as f32, position[2] as f32])?;
        let confidence = number(point.get("confidence"), 1.)?;
        if confidence < 0. {
            return Err(invalid());
        }
        if !point
            .get("source")
            .and_then(Value::as_str)
            .is_some_and(|s| matches!(s, "manual" | "detected"))
        {
            return Err(invalid());
        }
        if let Some(name) = point.get("name") {
            check_text(
                Some(name.as_str().ok_or_else(invalid)?),
                120,
                "Destination name",
            )?;
        }
        if let Some(slope) = point.get("slopeDegrees").filter(|v| !v.is_null()) {
            number(Some(slope), 90.)?;
        }
        if let Some(assistance) = point.get("requiresAssistance")
            && !assistance.is_boolean()
        {
            return Err(invalid());
        }
        // A place read from a sign carries what it said and the door and room it labels.
        if let Some(sign) = point.get("sign").filter(|v| !v.is_null()) {
            let sign = sign.as_object().ok_or_else(invalid)?;
            if let Some(text) = sign.get("text") {
                check_text(Some(text.as_str().ok_or_else(invalid)?), 256, "Sign text")?;
            }
            if let Some(room) = sign.get("room").filter(|v| !v.is_null())
                && !room.as_array().is_some_and(|corners| corners.len() <= 256)
            {
                return Err(invalid());
            }
            if serde_json::to_vec(sign).map_err(|_| invalid())?.len() > 16_384 {
                return Err(invalid());
            }
        }
    }
    if let Some(reference) = object.get("geographicReference").filter(|v| !v.is_null()) {
        number(reference.get("latitude"), 85.)?;
        number(reference.get("longitude"), 180.)?;
        number(reference.get("headingDegrees"), 100000.)?;
        if let Some(accuracy) = reference
            .get("horizontalAccuracyM")
            .filter(|v| !v.is_null())
            && number(Some(accuracy), 100000.)? < 0.
        {
            return Err(invalid());
        }
    }
    for key in [
        "requiresMeasuredFloorCoverage",
        "requiresOptimizedLocalization",
    ] {
        if let Some(value) = object.get(key).filter(|v| !v.is_null())
            && !value.is_boolean()
        {
            return Err(invalid());
        }
    }
    if object.get("requiresMeasuredFloorCoverage") == Some(&Value::Bool(true))
        && !footprints
            .iter()
            .any(|s| s.get("kind").and_then(Value::as_str) == Some("floor"))
    {
        return Err(ApiError::invalid("This map needs observed floor coverage."));
    }
    Ok(())
}
fn number(value: Option<&Value>, bound: f64) -> Result<f64, ApiError> {
    value
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite() && n.abs() <= bound)
        .ok_or_else(|| ApiError::invalid("The map contains invalid measurements."))
}
fn vector(value: Option<&Value>, len: usize, bound: f64) -> Result<Vec<f64>, ApiError> {
    let values = value
        .and_then(Value::as_array)
        .filter(|v| v.len() == len)
        .ok_or_else(|| ApiError::invalid("The map contains invalid positions."))?;
    values
        .iter()
        .map(|value| number(Some(value), bound))
        .collect()
}

#[cfg(test)]
mod identity_tests {
    use super::*;
    use axum::response::IntoResponse;
    use serde_json::json;

    const EMAIL: &str = "bootstrap@example.test";
    const PASSWORD: &str = "the existing bootstrap password";
    const LEGACY_TOKEN: &str = "1234567890123456789012345678901234567890123";

    fn legacy_store(role: Role) -> ProductStore {
        let root = std::env::temp_dir().join(format!("inview-legacy-identity-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        // Schema 1 before Auth0 had neither auth0_sub nor bootstrap_admin.
        fs::write(root.join("product.json"), serde_json::to_vec(&json!({
            "schema_version": 1,
            "accounts": { EMAIL: { "account": {"id": "legacy-id", "email": EMAIL, "name": "Legacy", "role": role},
                "password_hash": hash_password(PASSWORD).unwrap() } },
            "sessions": { digest_token(LEGACY_TOKEN): {"account_id": "legacy-id", "expires_at": now() + SESSION_SECONDS} },
            "submissions": {}, "retries": {}, "releases": []
        })).unwrap()).unwrap();
        ProductStore::open_inner(root, true).unwrap()
    }

    #[test]
    fn legacy_provenance_defaults_false_and_matching_bootstrap_migrates_and_revokes() {
        let store = legacy_store(Role::Admin);
        assert!(!store.inner.data.lock().unwrap().accounts[EMAIL].bootstrap_admin);
        assert_eq!(store.account(LEGACY_TOKEN).unwrap().id, "legacy-id");
        assert!(store.login_with(EMAIL, PASSWORD, true).is_err());
        store.bootstrap_admin(EMAIL, PASSWORD).unwrap();
        assert!(store.account(LEGACY_TOKEN).is_err());
        let session = store.login_with(EMAIL, PASSWORD, true).unwrap();
        assert_eq!(session.account.id, "legacy-id");
        assert!(session.expires_at <= now() + ADMIN_SESSION_SECONDS);
        let saved: Database =
            serde_json::from_slice(&fs::read(store.inner.root.join("product.json")).unwrap())
                .unwrap();
        assert!(saved.accounts[EMAIL].bootstrap_admin);
        assert!(!saved.sessions.contains_key(&digest_token(LEGACY_TOKEN)));
        // Repeated bootstrap is idempotent, not a logout on every server startup.
        store.bootstrap_admin(EMAIL, PASSWORD).unwrap();
        assert!(store.account(&session.token).is_ok());
        let linked = store
            .sign_in_external("email|bootstrap", EMAIL, None, false)
            .unwrap();
        assert_eq!(linked.account.role, Role::Admin);
        assert!(store.account(&session.token).is_err());
        assert!(store.login_with(EMAIL, PASSWORD, true).is_ok());
    }

    #[test]
    fn legacy_admin_without_explicit_bootstrap_is_demoted_on_external_sign_in() {
        let store = legacy_store(Role::Admin);
        let linked = store
            .sign_in_external("email|legacy", EMAIL, None, false)
            .unwrap();
        assert_eq!(linked.account.role, Role::User);
        assert_eq!(linked.account.id, "legacy-id");
        assert!(store.account(LEGACY_TOKEN).is_err());
        assert!(store.login_with(EMAIL, PASSWORD, true).is_err());
        assert!(!store.inner.data.lock().unwrap().accounts[EMAIL].bootstrap_admin);
    }

    #[test]
    fn bootstrap_conflicts_do_not_change_passwords_provenance_or_sessions() {
        let store = legacy_store(Role::Admin);
        let before = fs::read(store.inner.root.join("product.json")).unwrap();
        let error = store
            .bootstrap_admin(EMAIL, "a different long password")
            .unwrap_err();
        assert_eq!(error.into_response().status(), StatusCode::CONFLICT);
        assert_eq!(
            fs::read(store.inner.root.join("product.json")).unwrap(),
            before
        );
        assert!(store.account(LEGACY_TOKEN).is_ok());
        assert!(!store.inner.data.lock().unwrap().accounts[EMAIL].bootstrap_admin);

        let passwordless = ProductStore::default();
        let external = passwordless
            .sign_in_external("apple|admin", EMAIL, None, true)
            .unwrap();
        let before = fs::read(passwordless.inner.root.join("product.json")).unwrap();
        let error = passwordless.bootstrap_admin(EMAIL, PASSWORD).unwrap_err();
        assert_eq!(error.into_response().status(), StatusCode::CONFLICT);
        assert_eq!(
            fs::read(passwordless.inner.root.join("product.json")).unwrap(),
            before
        );
        assert!(passwordless.account(&external.token).is_ok());
        assert!(passwordless.login_with(EMAIL, PASSWORD, true).is_err());

        let user = legacy_store(Role::User);
        assert_eq!(
            user.bootstrap_admin(EMAIL, PASSWORD)
                .unwrap_err()
                .into_response()
                .status(),
            StatusCode::CONFLICT
        );
        assert!(user.account(LEGACY_TOKEN).is_ok());
    }

    #[test]
    fn explicit_bootstrap_provenance_and_revocation_survive_reopening() {
        let root = std::env::temp_dir().join(format!("inview-bootstrap-reopen-{}", Uuid::new_v4()));
        let store = ProductStore::open(&root).unwrap();
        store.bootstrap_admin(EMAIL, PASSWORD).unwrap();
        let old = store.login_with(EMAIL, PASSWORD, true).unwrap();
        let linked = store
            .sign_in_external("email|bootstrap", EMAIL, None, false)
            .unwrap();
        drop(store);
        let store = ProductStore::open_inner(root, true).unwrap();
        assert!(store.account(&old.token).is_err());
        assert_eq!(store.account(&linked.token).unwrap().role, Role::Admin);
        assert!(store.inner.data.lock().unwrap().accounts[EMAIL].bootstrap_admin);
        assert!(store.login_with(EMAIL, PASSWORD, true).is_ok());
    }

    #[test]
    fn failed_link_persistence_does_not_partially_revoke_or_bind() {
        let store = legacy_store(Role::User);
        // Force the atomic rename to fail without damaging the original file.
        let path = store.inner.root.join("product.json");
        let backup = store.inner.root.join("product.backup");
        fs::rename(&path, &backup).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(
            store
                .sign_in_external("apple|owner", EMAIL, None, true)
                .is_err()
        );
        assert_eq!(store.account(LEGACY_TOKEN).unwrap().role, Role::User);
        assert!(
            store.inner.data.lock().unwrap().accounts[EMAIL]
                .auth0_sub
                .is_none()
        );
        fs::remove_dir(&path).unwrap();
        fs::rename(&backup, &path).unwrap();
        let owner = store
            .sign_in_external("apple|owner", EMAIL, None, true)
            .unwrap();
        assert!(store.account(LEGACY_TOKEN).is_err());
        assert_eq!(store.account(&owner.token).unwrap().role, Role::Admin);
    }
}
