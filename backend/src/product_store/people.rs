//! Consent-based live location sharing between people who found each other.
//!
//! A share is always one person (the sharer) letting one other (the viewer) see where they are, for
//! a bounded time, until either side ends it. It starts either as an offer (active at once) or as a
//! request the sharer must accept. Positions are held in memory only, never written to disk, and
//! are only kept while at least one active share exists for the sharer.
use super::*;

const DEFAULT_MINUTES: u64 = 60;
const MIN_MINUTES: u64 = 5;
const MAX_MINUTES: u64 = 8 * 60;
const MAX_SHARES_PER_ACCOUNT: usize = 50;
/// A position older than this is not shown as "live".
pub const POSITION_FRESH_SECONDS: u64 = 60;
const POSITION_RATE: u8 = 250;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ShareState {
    Requested,
    Active,
    Declined,
    Revoked,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct LocationShare {
    pub id: String,
    /// The account whose position is shared.
    pub sharer: String,
    /// The account allowed to see it.
    pub viewer: String,
    pub state: ShareState,
    pub requested_by: String,
    pub created_at: u64,
    /// Set when the share becomes active.
    pub expires_at: Option<u64>,
}

impl LocationShare {
    fn is_live(&self, at: u64) -> bool {
        self.state == ShareState::Active && self.expires_at.is_some_and(|end| end > at)
    }
    fn is_open(&self, at: u64) -> bool {
        self.state == ShareState::Requested || self.is_live(at)
    }
}

/// A position in the shared map frame of a published venue.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Position {
    pub venue_id: String,
    pub floor: i32,
    pub x: f32,
    pub z: f32,
    #[serde(default)]
    pub heading_deg: Option<f32>,
    #[serde(default)]
    pub accuracy_m: Option<f32>,
    #[serde(default, skip_deserializing)]
    pub updated_at: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct ShareView {
    pub id: String,
    /// `outgoing`: you share with them. `incoming`: they share with you.
    pub direction: &'static str,
    /// `requested`, `active`, `declined`, `revoked` or `expired`.
    pub state: &'static str,
    pub person: Person,
    pub expires_at: Option<u64>,
    /// Whether the request or offer came from you.
    pub started_by_me: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct PersonLocation {
    pub person: Person,
    #[serde(flatten)]
    pub position: Position,
    pub age_seconds: u64,
    pub share_expires_at: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ShareMode {
    /// I let them see me.
    Offer,
    /// I ask to see them.
    Request,
}

fn share_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "share_not_found",
        "That location share doesn't exist or has ended.",
    )
}
fn clamp_minutes(minutes: Option<u64>) -> u64 {
    minutes
        .unwrap_or(DEFAULT_MINUTES)
        .clamp(MIN_MINUTES, MAX_MINUTES)
}

fn find_by_person<'a>(db: &'a Database, person: &str) -> Option<&'a StoredAccount> {
    db.accounts
        .values()
        .find(|a| person_id(&a.account.id) == person)
}

impl ProductStore {
    fn state_label(share: &LocationShare, at: u64) -> &'static str {
        match share.state {
            ShareState::Requested => "requested",
            ShareState::Declined => "declined",
            ShareState::Revoked => "revoked",
            ShareState::Active if share.is_live(at) => "active",
            ShareState::Active => "expired",
        }
    }

    /// Starts a share with another discoverable person. `person` is the opaque id a lookup returned.
    pub fn start_share(
        &self,
        me: &Account,
        person: &str,
        mode: ShareMode,
        minutes: Option<u64>,
    ) -> Result<ShareView, ApiError> {
        let at = now();
        let duration = clamp_minutes(minutes) * 60;
        let view = self.transaction(|db| {
            let other = find_by_person(db, person)
                .filter(|a| a.discoverable && a.account.id != me.id)
                .map(|a| a.account.id.clone())
                .ok_or_else(person_not_found)?;
            let (sharer, viewer) = match mode {
                ShareMode::Offer => (me.id.clone(), other.clone()),
                ShareMode::Request => (other.clone(), me.id.clone()),
            };
            let mine = db
                .shares
                .iter()
                .filter(|s| (s.sharer == me.id || s.viewer == me.id) && s.is_open(at))
                .count();
            // The pair may already have an open share in this direction: reuse it.
            let existing = db
                .shares
                .iter()
                .position(|s| s.sharer == sharer && s.viewer == viewer && s.is_open(at));
            let index = match existing {
                Some(index) => index,
                None => {
                    if mine >= MAX_SHARES_PER_ACCOUNT {
                        return Err(ApiError::new(
                            StatusCode::CONFLICT,
                            "too_many_shares",
                            "End a location share before starting another.",
                        ));
                    }
                    db.shares.push(LocationShare {
                        id: Uuid::new_v4().to_string(),
                        sharer: sharer.clone(),
                        viewer: viewer.clone(),
                        state: ShareState::Requested,
                        requested_by: me.id.clone(),
                        created_at: at,
                        expires_at: None,
                    });
                    db.shares.len() - 1
                }
            };
            let share = &mut db.shares[index];
            // An offer, or answering a request they made by offering, is the sharer consenting now.
            if mode == ShareMode::Offer {
                share.state = ShareState::Active;
                share.expires_at = Some(at + duration);
            }
            Ok(share.clone())
        })?;
        self.share_view(me, &view)
    }

    fn share_view(&self, me: &Account, share: &LocationShare) -> Result<ShareView, ApiError> {
        let db = self.inner.data.lock().map_err(storage_error)?;
        Ok(view_of(&db, me, share, now()))
    }

    pub fn list_shares(&self, me: &Account) -> Result<Vec<ShareView>, ApiError> {
        let db = self.inner.data.lock().map_err(storage_error)?;
        let at = now();
        let mut views: Vec<(u64, ShareView)> = db
            .shares
            .iter()
            .filter(|s| s.sharer == me.id || s.viewer == me.id)
            .map(|s| (s.created_at, view_of(&db, me, s, at)))
            .collect();
        views.sort_by_key(|view| std::cmp::Reverse(view.0));
        Ok(views.into_iter().map(|(_, v)| v).take(100).collect())
    }

    /// The sharer answers a request. Accepting makes it active for `minutes`.
    pub fn respond_share(
        &self,
        me: &Account,
        id: &str,
        accept: bool,
        minutes: Option<u64>,
    ) -> Result<ShareView, ApiError> {
        let at = now();
        let duration = clamp_minutes(minutes) * 60;
        let share = self.transaction(|db| {
            let share = db
                .shares
                .iter_mut()
                .find(|s| s.id == id && s.sharer == me.id && s.state == ShareState::Requested)
                .ok_or_else(share_not_found)?;
            if accept {
                share.state = ShareState::Active;
                share.expires_at = Some(at + duration);
            } else {
                share.state = ShareState::Declined;
            }
            Ok(share.clone())
        })?;
        self.share_view(me, &share)
    }

    /// Either side can end a share at any time.
    pub fn end_share(&self, me: &Account, id: &str) -> Result<(), ApiError> {
        let at = now();
        let sharer = self.transaction(|db| {
            let share = db
                .shares
                .iter_mut()
                .find(|s| s.id == id && (s.sharer == me.id || s.viewer == me.id) && s.is_open(at))
                .ok_or_else(share_not_found)?;
            share.state = ShareState::Revoked;
            Ok(share.sharer.clone())
        })?;
        self.forget_position_if_unshared(&sharer);
        Ok(())
    }

    fn has_live_outgoing(&self, account_id: &str) -> Result<bool, ApiError> {
        let db = self.inner.data.lock().map_err(storage_error)?;
        let at = now();
        Ok(db
            .shares
            .iter()
            .any(|s| s.sharer == account_id && s.is_live(at)))
    }

    fn forget_position_if_unshared(&self, account_id: &str) {
        if !self.has_live_outgoing(account_id).unwrap_or(false)
            && let Ok(mut positions) = self.inner.positions.lock()
        {
            positions.remove(account_id);
        }
    }

    /// Records the caller's position, but only while they are sharing with someone. Returns whether
    /// it was kept, so an app can stop sending when nobody can see it.
    pub fn publish_position(&self, me: &Account, position: Position) -> Result<bool, ApiError> {
        self.attempt(&format!("position:{}", me.id), POSITION_RATE)?;
        let valid_venue = !position.venue_id.is_empty()
            && position.venue_id.len() <= 64
            && position
                .venue_id
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_');
        let finite = |v: f32| v.is_finite() && v.abs() < 10_000.0;
        if !valid_venue
            || !(-20..=200).contains(&position.floor)
            || !finite(position.x)
            || !finite(position.z)
            || position.heading_deg.is_some_and(|h| !h.is_finite())
            || position
                .accuracy_m
                .is_some_and(|a| !(a.is_finite() && (0.0..=1000.0).contains(&a)))
        {
            return Err(ApiError::invalid(
                "Send a venue id, floor and finite x and z.",
            ));
        }
        if !self.has_live_outgoing(&me.id)? {
            self.forget_position_if_unshared(&me.id);
            return Ok(false);
        }
        let mut stored = position;
        stored.updated_at = now();
        self.inner
            .positions
            .lock()
            .map_err(storage_error)?
            .insert(me.id.clone(), stored);
        Ok(true)
    }

    /// The live position of a person who is sharing with you right now.
    pub fn person_location(&self, me: &Account, person: &str) -> Result<PersonLocation, ApiError> {
        self.attempt(&format!("locate:{}", me.id), POSITION_RATE)?;
        let at = now();
        let (sharer, share_end, view) = {
            let db = self.inner.data.lock().map_err(storage_error)?;
            let stored = find_by_person(&db, person).ok_or_else(share_not_found)?;
            let share = db
                .shares
                .iter()
                .find(|s| s.sharer == stored.account.id && s.viewer == me.id && s.is_live(at))
                .ok_or_else(share_not_found)?;
            (
                stored.account.id.clone(),
                share.expires_at.unwrap_or(at),
                person_of(stored),
            )
        };
        let position = self
            .inner
            .positions
            .lock()
            .map_err(storage_error)?
            .get(&sharer)
            .cloned()
            .filter(|p| at.saturating_sub(p.updated_at) <= POSITION_FRESH_SECONDS)
            .ok_or_else(|| {
                ApiError::new(
                    StatusCode::NOT_FOUND,
                    "location_unavailable",
                    "They haven't shared a recent position. They may be outside the mapped area or offline.",
                )
            })?;
        Ok(PersonLocation {
            person: view,
            age_seconds: at.saturating_sub(position.updated_at),
            position,
            share_expires_at: share_end,
        })
    }
}

fn view_of(db: &Database, me: &Account, share: &LocationShare, at: u64) -> ShareView {
    let outgoing = share.sharer == me.id;
    let other = if outgoing {
        &share.viewer
    } else {
        &share.sharer
    };
    let person = db
        .accounts
        .values()
        .find(|a| &a.account.id == other)
        .map(person_of)
        .unwrap_or(Person {
            person_id: person_id(other),
            name: "InView user".into(),
            handle: None,
        });
    ShareView {
        id: share.id.clone(),
        direction: if outgoing { "outgoing" } else { "incoming" },
        state: ProductStore::state_label(share, at),
        person,
        expires_at: share.expires_at,
        started_by_me: share.requested_by == me.id,
    }
}
