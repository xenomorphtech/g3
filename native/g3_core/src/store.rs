use std::{fs, path::PathBuf};

use anyhow::{Context, Result};
use chrono::Utc;
use parking_lot::RwLock;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    models::{
        DraftCompletion, HistoryEntry, ItemFields, ItemKind, PublicSnapshot, StoredSnapshot,
        TrackerItem,
    },
    spacetimedb_store::{SpacetimeStoreConfig, SpacetimeWorkspaceStore},
};

pub struct WorkspaceStore {
    inner: StoreBackend,
}

enum StoreBackend {
    File(FileWorkspaceStore),
    Spacetime(SpacetimeWorkspaceStore),
}

struct FileWorkspaceStore {
    path: PathBuf,
    state: RwLock<StoredSnapshot>,
}

#[derive(Debug, Error)]
pub enum SaveDraftError {
    #[error("There is no active draft to save.")]
    MissingDraft,
    #[error("{0}")]
    Incomplete(String),
    #[error(transparent)]
    Io(#[from] anyhow::Error),
}

impl WorkspaceStore {
    pub fn load(path: impl Into<PathBuf>) -> Result<Self> {
        Ok(Self {
            inner: StoreBackend::File(FileWorkspaceStore::load(path)?),
        })
    }

    pub fn spacetimedb(config: SpacetimeStoreConfig) -> Result<Self> {
        Ok(Self {
            inner: StoreBackend::Spacetime(SpacetimeWorkspaceStore::connect(config)?),
        })
    }

    pub fn snapshot(&self) -> PublicSnapshot {
        match &self.inner {
            StoreBackend::File(store) => store.snapshot(),
            StoreBackend::Spacetime(store) => store.snapshot(),
        }
    }

    pub fn reset(&self) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.reset(),
            StoreBackend::Spacetime(store) => store.reset(),
        }
    }

    pub fn upsert_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.upsert_draft(kind, fields),
            StoreBackend::Spacetime(store) => store.upsert_draft(kind, fields),
        }
    }

    pub fn start_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.start_draft(kind, fields),
            StoreBackend::Spacetime(store) => store.start_draft(kind, fields),
        }
    }

    pub fn clear_draft(&self) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.clear_draft(),
            StoreBackend::Spacetime(store) => store.clear_draft(),
        }
    }

    pub fn activate_draft(&self, kind: &ItemKind, id: &str) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.activate_draft(kind, id),
            StoreBackend::Spacetime(store) => {
                let _ = kind;
                store.activate_draft(id)
            }
        }
    }

    pub fn reorder_goals(&self, ids: &[String]) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.reorder_goals(ids),
            StoreBackend::Spacetime(store) => store.reorder_goals(ids),
        }
    }

    pub fn save_draft(&self) -> std::result::Result<PublicSnapshot, SaveDraftError> {
        match &self.inner {
            StoreBackend::File(store) => store.save_draft(),
            StoreBackend::Spacetime(store) => store.save_draft().map_err(map_spacetime_save_error),
        }
    }

    pub fn put_object_conversation(
        &self,
        kind: &ItemKind,
        id: &str,
        conversation: Vec<HistoryEntry>,
    ) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.put_object_conversation(kind, id, conversation),
            StoreBackend::Spacetime(store) => {
                let _ = kind;
                store.put_object_conversation(id, conversation)
            }
        }
    }

    pub fn put_object_summary(
        &self,
        kind: &ItemKind,
        id: &str,
        summary: String,
    ) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.put_object_summary(kind, id, summary),
            StoreBackend::Spacetime(store) => {
                let _ = kind;
                store.put_object_summary(id, summary)
            }
        }
    }

    pub fn clear_object_conversation(&self, kind: &ItemKind, id: &str) -> Result<PublicSnapshot> {
        match &self.inner {
            StoreBackend::File(store) => store.clear_object_conversation(kind, id),
            StoreBackend::Spacetime(store) => {
                let _ = kind;
                store.clear_object_conversation(id)
            }
        }
    }
}

impl FileWorkspaceStore {
    fn load(path: impl Into<PathBuf>) -> Result<Self> {
        let path = path.into();
        let now = now_timestamp();
        let snapshot = match fs::read_to_string(&path) {
            Ok(encoded) => serde_json::from_str(&encoded)
                .with_context(|| format!("failed to decode {}", path.display()))?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => StoredSnapshot::empty(&now),
            Err(err) => {
                return Err(anyhow::Error::new(err))
                    .with_context(|| format!("failed to read {}", path.display()))
            }
        };

        let store = Self {
            path,
            state: RwLock::new(snapshot),
        };
        store.persist()?;
        Ok(store)
    }

    fn snapshot(&self) -> PublicSnapshot {
        self.state.read().public_snapshot()
    }

    fn reset(&self) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            *state = StoredSnapshot::empty(&now);
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn upsert_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            match current_draft_index(&state) {
                None => state
                    .bucket_mut(&kind)
                    .insert(0, TrackerItem::new_draft(kind, fields, &now)),
                Some((current_kind, _)) if current_kind != kind => {
                    archive_current_draft_locked(&mut state, &now);
                    state
                        .bucket_mut(&kind)
                        .insert(0, TrackerItem::new_draft(kind, fields, &now));
                }
                Some((current_kind, current_index)) => {
                    let item = state.bucket_mut(&current_kind).get_mut(current_index).unwrap();
                    item.apply_fields(fields, &now);
                    item.status = Some("being_drafted".to_string());
                    item.id = "draft-current".to_string();
                }
            }
            state.updated_at = now;
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn start_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            archive_current_draft_locked(&mut state, &now);
            state
                .bucket_mut(&kind)
                .insert(0, TrackerItem::new_draft(kind, fields, &now));
            state.updated_at = now;
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn clear_draft(&self) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            remove_current_draft_locked(&mut state);
            state.updated_at = now;
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn activate_draft(&self, kind: &ItemKind, id: &str) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            let Some(target) = state.find_item(kind, id).cloned() else {
                return Ok(state.public_snapshot());
            };

            if target.id == "draft-current" {
                if let Some(item) = state
                    .bucket_mut(kind)
                    .iter_mut()
                    .find(|item| item.id == "draft-current")
                {
                    item.updated_at = now.clone();
                }
            } else if target.is_drafting() {
                archive_current_draft_locked(&mut state, &now);
                if let Some(item) = state.bucket_mut(kind).iter_mut().find(|item| item.id == id) {
                    item.id = "draft-current".to_string();
                    item.updated_at = now.clone();
                }
            }
            state.updated_at = now;
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn reorder_goals(&self, ids: &[String]) -> Result<PublicSnapshot> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            let mut ordered = Vec::new();
            let mut remaining = Vec::new();

            for item in state.goals.drain(..) {
                if ids.iter().any(|id| id == &item.id) {
                    ordered.push(item);
                } else {
                    remaining.push(item);
                }
            }

            ordered.sort_by_key(|item| {
                ids.iter()
                    .position(|id| id == &item.id)
                    .unwrap_or(usize::MAX)
            });
            ordered.extend(remaining);
            state.goals = ordered;
            state.updated_at = now;
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn save_draft(&self) -> std::result::Result<PublicSnapshot, SaveDraftError> {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            let Some((kind, index)) = current_draft_index(&state) else {
                return Err(SaveDraftError::MissingDraft);
            };

            let draft = state.bucket(&kind)[index].clone();
            let completion = DraftCompletion::from_item(Some(&draft));
            if !completion.ready {
                return Err(SaveDraftError::Incomplete(completion.missing.join(" ")));
            }

            let saved = persisted_item(draft, &now);
            state.bucket_mut(&kind).remove(index);
            state.bucket_mut(&kind).insert(0, saved);
            state.updated_at = now;
        }

        self.persist().map_err(SaveDraftError::Io)?;
        Ok(self.snapshot())
    }

    fn put_object_conversation(
        &self,
        kind: &ItemKind,
        id: &str,
        conversation: Vec<HistoryEntry>,
    ) -> Result<PublicSnapshot> {
        self.update_item(kind, id, |item, now| {
            item.origin_conversation = Some(conversation.clone());
            item.updated_at = now.to_string();
        })
    }

    fn put_object_summary(
        &self,
        kind: &ItemKind,
        id: &str,
        summary: String,
    ) -> Result<PublicSnapshot> {
        self.update_item(kind, id, |item, now| {
            item.origin_summary = Some(summary.clone());
            item.updated_at = now.to_string();
        })
    }

    fn clear_object_conversation(&self, kind: &ItemKind, id: &str) -> Result<PublicSnapshot> {
        self.update_item(kind, id, |item, now| {
            item.origin_conversation = None;
            item.origin_summary = None;
            item.updated_at = now.to_string();
        })
    }

    fn update_item<F>(&self, kind: &ItemKind, id: &str, mut update: F) -> Result<PublicSnapshot>
    where
        F: FnMut(&mut TrackerItem, &str),
    {
        let now = now_timestamp();
        {
            let mut state = self.state.write();
            if let Some(item) = state.bucket_mut(kind).iter_mut().find(|item| item.id == id) {
                update(item, &now);
                state.updated_at = now;
            }
        }
        self.persist()?;
        Ok(self.snapshot())
    }

    fn persist(&self) -> Result<()> {
        let state = self.state.read();
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }

        let encoded = serde_json::to_string_pretty(&*state)?;
        fs::write(&self.path, format!("{encoded}\n"))
            .with_context(|| format!("failed to write {}", self.path.display()))
    }
}

fn map_spacetime_save_error(error: anyhow::Error) -> SaveDraftError {
    let message = error.to_string();
    if message == "There is no active draft to save." {
        SaveDraftError::MissingDraft
    } else if !message.is_empty() {
        SaveDraftError::Incomplete(message)
    } else {
        SaveDraftError::Io(error)
    }
}

fn current_draft_index(state: &StoredSnapshot) -> Option<(ItemKind, usize)> {
    for (kind, bucket) in [
        (ItemKind::Goal, &state.goals),
        (ItemKind::Task, &state.tasks),
        (ItemKind::Fact, &state.facts),
    ] {
        if let Some(index) = bucket
            .iter()
            .position(|item| item.id == "draft-current" && item.is_drafting())
        {
            return Some((kind, index));
        }
    }

    None
}

fn archive_current_draft_locked(state: &mut StoredSnapshot, now: &str) {
    if let Some((kind, index)) = current_draft_index(state) {
        if let Some(item) = state.bucket_mut(&kind).get_mut(index) {
            item.id = format!("draft-{}-{}", kind.as_str(), Uuid::new_v4());
            item.updated_at = now.to_string();
        }
    }
}

fn remove_current_draft_locked(state: &mut StoredSnapshot) {
    state.goals.retain(|item| item.id != "draft-current");
    state.tasks.retain(|item| item.id != "draft-current");
    state.facts.retain(|item| item.id != "draft-current");
}

fn persisted_item(mut draft: TrackerItem, now: &str) -> TrackerItem {
    draft.id = format!("{}-{}", draft.kind.as_str(), Uuid::new_v4().simple());
    draft.status = Some(draft.kind.persisted_status().to_string());
    draft.inserted_at = Some(now.to_string());
    draft.updated_at = now.to_string();
    draft
}

pub fn now_timestamp() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}
