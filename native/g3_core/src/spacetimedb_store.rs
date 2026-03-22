use std::{future::Future, time::Duration};

use anyhow::{anyhow, Context, Result};
use parking_lot::RwLock;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use tokio::{
    runtime::{Builder, Handle},
    task,
};

use crate::models::{HistoryEntry, ItemFields, ItemKind, PublicSnapshot, TrackerItem};

#[derive(Debug, Clone)]
pub struct SpacetimeStoreConfig {
    pub base_url: String,
    pub database: String,
}

impl SpacetimeStoreConfig {
    pub fn new(base_url: impl Into<String>, database: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            database: database.into(),
        }
    }
}

pub struct SpacetimeWorkspaceStore {
    base_url: String,
    database: String,
    client: Client,
    state: RwLock<PublicSnapshot>,
}

impl SpacetimeWorkspaceStore {
    pub fn connect(config: SpacetimeStoreConfig) -> Result<Self> {
        let client = Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .context("failed to build SpaceTimeDB client")?;

        let store = Self {
            base_url: config.base_url.trim_end_matches('/').to_string(),
            database: config.database,
            client,
            state: RwLock::new(empty_snapshot()),
        };

        let snapshot = store.fetch_snapshot()?;
        *store.state.write() = snapshot;
        Ok(store)
    }

    pub fn snapshot(&self) -> PublicSnapshot {
        self.state.read().clone()
    }

    pub fn reset(&self) -> Result<PublicSnapshot> {
        self.call_reducer("reset_workspace", &EmptyInput {})?;
        self.refresh_snapshot()
    }

    pub fn upsert_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        self.call_reducer(
            "upsert_draft",
            &DraftMutation {
                kind: kind.as_str().to_string(),
                fields: fields.into(),
            },
        )?;
        self.refresh_snapshot()
    }

    pub fn start_draft(&self, kind: ItemKind, fields: ItemFields) -> Result<PublicSnapshot> {
        self.call_reducer(
            "start_draft",
            &DraftMutation {
                kind: kind.as_str().to_string(),
                fields: fields.into(),
            },
        )?;
        self.refresh_snapshot()
    }

    pub fn clear_draft(&self) -> Result<PublicSnapshot> {
        self.call_reducer("clear_draft", &EmptyInput {})?;
        self.refresh_snapshot()
    }

    pub fn activate_draft(&self, id: &str) -> Result<PublicSnapshot> {
        self.call_reducer(
            "activate_draft",
            &ItemRef {
                item_id: id.to_string(),
            },
        )?;
        self.refresh_snapshot()
    }

    pub fn reorder_goals(&self, ids: &[String]) -> Result<PublicSnapshot> {
        self.call_reducer("reorder_goals", &ReorderGoalsInput { ids: ids.to_vec() })?;
        self.refresh_snapshot()
    }

    pub fn save_draft(&self) -> Result<PublicSnapshot> {
        self.call_reducer("save_draft", &EmptyInput {})?;
        self.refresh_snapshot()
    }

    pub fn put_object_conversation(
        &self,
        id: &str,
        conversation: Vec<HistoryEntry>,
    ) -> Result<PublicSnapshot> {
        self.call_reducer(
            "put_object_conversation",
            &ConversationInput {
                item_id: id.to_string(),
                conversation,
            },
        )?;
        self.refresh_snapshot()
    }

    pub fn put_object_summary(&self, id: &str, summary: String) -> Result<PublicSnapshot> {
        self.call_reducer(
            "put_object_summary",
            &SummaryInput {
                item_id: id.to_string(),
                summary,
            },
        )?;
        self.refresh_snapshot()
    }

    pub fn clear_object_conversation(&self, id: &str) -> Result<PublicSnapshot> {
        self.call_reducer(
            "clear_object_conversation",
            &ItemRef {
                item_id: id.to_string(),
            },
        )?;
        self.refresh_snapshot()
    }

    fn refresh_snapshot(&self) -> Result<PublicSnapshot> {
        let snapshot = self.fetch_snapshot()?;
        *self.state.write() = snapshot.clone();
        Ok(snapshot)
    }

    fn fetch_snapshot(&self) -> Result<PublicSnapshot> {
        let updated_at = self
            .query_json_rows("SELECT * FROM workspace_meta WHERE id = 1;")?
            .into_iter()
            .next()
            .and_then(|row| row.as_array().cloned())
            .and_then(|row| row.get(1).and_then(|value| value.as_str()).map(str::to_string))
            .unwrap_or_else(crate::store::now_timestamp);

        let mut rows = self
            .query_json_rows("SELECT * FROM tracker_item;")?
            .into_iter()
            .map(TrackerItemRow::from_value)
            .collect::<Result<Vec<_>>>()?;
        rows.sort_by(|left, right| right.sort_key.cmp(&left.sort_key));

        let mut snapshot = PublicSnapshot {
            goals: Vec::new(),
            tasks: Vec::new(),
            facts: Vec::new(),
            updated_at,
            active_draft: None,
        };

        for row in rows {
            let item = row.into_tracker_item()?;
            match item.kind {
                ItemKind::Goal => snapshot.goals.push(item),
                ItemKind::Task => snapshot.tasks.push(item),
                ItemKind::Fact => snapshot.facts.push(item),
            }
        }

        snapshot.active_draft = snapshot
            .goals
            .iter()
            .chain(snapshot.tasks.iter())
            .chain(snapshot.facts.iter())
            .find(|item| item.is_drafting() && item.id == "draft-current")
            .cloned();

        Ok(snapshot)
    }

    fn call_reducer<T>(&self, reducer: &str, payload: &T) -> Result<()>
    where
        T: Serialize,
    {
        let url = format!(
            "{}/v1/database/{}/call/{}",
            self.base_url, self.database, reducer
        );
        let response = self
            .run_async(async {
                let response = self
                    .client
                    .post(&url)
                    .header(reqwest::header::CONTENT_TYPE, "application/json")
                    .json(&ReducerBody { input: payload })
                    .send()
                    .await?;
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                Ok::<_, reqwest::Error>((status, body))
            })
            .with_context(|| format!("failed to call SpaceTimeDB reducer `{reducer}`"))?;

        let (status, body) = response;
        if status.is_success() {
            Ok(())
        } else if body.trim().is_empty() {
            Err(anyhow!(
                "SpaceTimeDB reducer `{reducer}` failed with status {status}"
            ))
        } else {
            Err(anyhow!(body.trim().to_string()))
        }
    }

    fn query_json_rows(&self, sql: &str) -> Result<Vec<serde_json::Value>> {
        let url = format!("{}/v1/database/{}/sql", self.base_url, self.database);
        let response = self
            .run_async(async {
                let response = self.client.post(&url).body(sql.to_string()).send().await?;
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                Ok::<_, reqwest::Error>((status, body))
            })
            .with_context(|| format!("failed to query SpaceTimeDB with `{sql}`"))?;

        let (status, body) = response;
        if !status.is_success() {
            if body.trim().is_empty() {
                return Err(anyhow!(
                    "SpaceTimeDB SQL request failed with status {status}"
                ));
            }
            return Err(anyhow!(body.trim().to_string()));
        }

        let results: Vec<SqlStmtResult<serde_json::Value>> =
            serde_json::from_str(&body).context("failed to decode SpaceTimeDB SQL response")?;
        Ok(results
            .into_iter()
            .flat_map(|result| result.rows.into_iter())
            .collect())
    }

    fn run_async<F, T>(&self, future: F) -> T
    where
        F: Future<Output = T>,
    {
        match Handle::try_current() {
            Ok(handle) => task::block_in_place(|| handle.block_on(future)),
            Err(_) => Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("failed to build temporary SpaceTimeDB runtime")
                .block_on(future),
        }
    }
}

#[derive(Debug, Default, Serialize)]
struct EmptyInput {}

#[derive(Debug, Serialize)]
struct ReducerBody<'a, T> {
    input: &'a T,
}

#[derive(Debug, Serialize)]
struct ItemRef {
    item_id: String,
}

#[derive(Debug, Serialize)]
struct SummaryInput {
    item_id: String,
    summary: String,
}

#[derive(Debug, Serialize)]
struct ConversationInput {
    item_id: String,
    conversation: Vec<HistoryEntry>,
}

#[derive(Debug, Serialize)]
struct ReorderGoalsInput {
    ids: Vec<String>,
}

#[derive(Debug, Serialize)]
struct DraftMutation {
    kind: String,
    fields: SpacetimeItemFields,
}

#[derive(Debug, Default, Serialize)]
struct SpacetimeItemFields {
    title: String,
    summary: String,
    details: String,
    status: String,
    success_criteria: String,
    target_date: String,
    due_date: String,
    priority: String,
    parent_goal_title: String,
    project_title: String,
}

impl From<ItemFields> for SpacetimeItemFields {
    fn from(value: ItemFields) -> Self {
        Self {
            title: value.title.unwrap_or_default(),
            summary: value.summary.unwrap_or_default(),
            details: value.details.unwrap_or_default(),
            status: value.status.unwrap_or_default(),
            success_criteria: value.success_criteria.unwrap_or_default(),
            target_date: value.target_date.unwrap_or_default(),
            due_date: value.due_date.unwrap_or_default(),
            priority: value.priority.unwrap_or_default(),
            parent_goal_title: value.parent_goal_title.unwrap_or_default(),
            project_title: value.project_title.unwrap_or_default(),
        }
    }
}

#[derive(Debug, Deserialize)]
struct SqlStmtResult<Row> {
    rows: Vec<Row>,
}

struct TrackerItemRow {
    item_id: String,
    kind: String,
    sort_key: i64,
    title: String,
    summary: String,
    details: String,
    status: String,
    success_criteria: String,
    target_date: String,
    due_date: String,
    priority: String,
    parent_goal_title: String,
    project_title: String,
    origin_conversation_json: String,
    origin_summary: String,
    inserted_at: String,
    updated_at: String,
}

impl TrackerItemRow {
    fn from_value(row: serde_json::Value) -> Result<Self> {
        let cells = row
            .as_array()
            .ok_or_else(|| anyhow!("expected SpaceTimeDB row array"))?;

        Ok(Self {
            item_id: required_string(cells, 1, "item_id")?,
            kind: required_string(cells, 2, "kind")?,
            sort_key: required_i64(cells, 3, "sort_key")?,
            title: required_string(cells, 4, "title")?,
            summary: required_string(cells, 5, "summary")?,
            details: required_string(cells, 6, "details")?,
            status: required_string(cells, 7, "status")?,
            success_criteria: required_string(cells, 8, "success_criteria")?,
            target_date: required_string(cells, 9, "target_date")?,
            due_date: required_string(cells, 10, "due_date")?,
            priority: required_string(cells, 11, "priority")?,
            parent_goal_title: required_string(cells, 12, "parent_goal_title")?,
            project_title: required_string(cells, 13, "project_title")?,
            origin_conversation_json: required_string(cells, 14, "origin_conversation_json")?,
            origin_summary: required_string(cells, 15, "origin_summary")?,
            inserted_at: required_string(cells, 16, "inserted_at")?,
            updated_at: required_string(cells, 17, "updated_at")?,
        })
    }

    fn into_tracker_item(self) -> Result<TrackerItem> {
        Ok(TrackerItem {
            id: self.item_id,
            kind: parse_kind(&self.kind)?,
            title: optional_string(self.title),
            summary: optional_string(self.summary),
            details: optional_string(self.details),
            status: optional_string(self.status),
            success_criteria: optional_string(self.success_criteria),
            target_date: optional_string(self.target_date),
            due_date: optional_string(self.due_date),
            priority: optional_string(self.priority),
            parent_goal_title: optional_string(self.parent_goal_title),
            project_title: optional_string(self.project_title),
            origin_conversation: parse_history(self.origin_conversation_json)?,
            origin_summary: optional_string(self.origin_summary),
            inserted_at: optional_string(self.inserted_at),
            updated_at: self.updated_at,
        })
    }
}

fn empty_snapshot() -> PublicSnapshot {
    PublicSnapshot {
        goals: Vec::new(),
        tasks: Vec::new(),
        facts: Vec::new(),
        updated_at: crate::store::now_timestamp(),
        active_draft: None,
    }
}

fn parse_kind(kind: &str) -> Result<ItemKind> {
    match kind {
        "goal" => Ok(ItemKind::Goal),
        "task" => Ok(ItemKind::Task),
        "fact" => Ok(ItemKind::Fact),
        other => Err(anyhow!("unsupported SpaceTimeDB item kind `{other}`")),
    }
}

fn optional_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn parse_history(encoded: String) -> Result<Option<Vec<HistoryEntry>>> {
    let trimmed = encoded.trim();
    if trimmed.is_empty() {
        Ok(None)
    } else {
        let entries = serde_json::from_str(trimmed).context("failed to decode stored conversation")?;
        Ok(Some(entries))
    }
}

fn required_string(
    row: &[serde_json::Value],
    index: usize,
    field: &str,
) -> Result<String> {
    row.get(index)
        .and_then(|value| value.as_str())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("missing SpaceTimeDB `{field}` column at index {index}"))
}

fn required_i64(row: &[serde_json::Value], index: usize, field: &str) -> Result<i64> {
    row.get(index)
        .and_then(|value| value.as_i64())
        .ok_or_else(|| anyhow!("missing SpaceTimeDB `{field}` column at index {index}"))
}
