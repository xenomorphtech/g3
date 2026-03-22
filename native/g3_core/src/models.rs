use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    Goal,
    Task,
    Fact,
}

impl ItemKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Goal => "goal",
            Self::Task => "task",
            Self::Fact => "fact",
        }
    }

    pub fn persisted_status(&self) -> &'static str {
        match self {
            Self::Goal => "draft",
            Self::Task => "planned",
            Self::Fact => "known",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct HistoryEntry {
    pub role: String,
    pub content: String,
    #[serde(default)]
    pub follow_up: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct ItemFields {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub success_criteria: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_goal_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_title: Option<String>,
}

impl ItemFields {
    pub fn is_empty(&self) -> bool {
        [
            &self.title,
            &self.summary,
            &self.details,
            &self.status,
            &self.success_criteria,
            &self.target_date,
            &self.due_date,
            &self.priority,
            &self.parent_goal_title,
            &self.project_title,
        ]
        .iter()
        .all(|field| field.is_none())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TrackerItem {
    pub id: String,
    pub kind: ItemKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub success_criteria: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub priority: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_goal_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub project_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_conversation: Option<Vec<HistoryEntry>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin_summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inserted_at: Option<String>,
    pub updated_at: String,
}

impl TrackerItem {
    pub fn new_draft(kind: ItemKind, fields: ItemFields, now: &str) -> Self {
        let mut item = Self {
            id: "draft-current".to_string(),
            kind,
            title: None,
            summary: None,
            details: None,
            status: Some("being_drafted".to_string()),
            success_criteria: None,
            target_date: None,
            due_date: None,
            priority: None,
            parent_goal_title: None,
            project_title: None,
            origin_conversation: None,
            origin_summary: None,
            inserted_at: None,
            updated_at: now.to_string(),
        };
        item.apply_fields(fields, now);
        item.status = Some("being_drafted".to_string());
        item.id = "draft-current".to_string();
        item
    }

    pub fn is_drafting(&self) -> bool {
        self.status.as_deref() == Some("being_drafted")
    }

    pub fn same_object(&self, other: &TrackerItem) -> bool {
        self.kind == other.kind
            && (self.id == other.id || (self.title.is_some() && self.title == other.title))
    }

    pub fn title_or(&self, fallback: &str) -> String {
        self.title.clone().unwrap_or_else(|| fallback.to_string())
    }

    pub fn lead_text(&self) -> Option<String> {
        self.summary
            .clone()
            .or_else(|| self.details.clone())
            .or_else(|| self.success_criteria.clone())
    }

    pub fn apply_fields(&mut self, fields: ItemFields, now: &str) {
        apply_field(&mut self.title, fields.title);
        apply_field(&mut self.summary, fields.summary);
        apply_field(&mut self.details, fields.details);
        apply_field(&mut self.status, fields.status);
        apply_field(&mut self.success_criteria, fields.success_criteria);
        apply_field(&mut self.target_date, fields.target_date);
        apply_field(&mut self.due_date, fields.due_date);
        apply_field(&mut self.priority, fields.priority);
        apply_field(&mut self.parent_goal_title, fields.parent_goal_title);
        apply_field(&mut self.project_title, fields.project_title);
        self.updated_at = now.to_string();
    }
}

fn apply_field(target: &mut Option<String>, value: Option<String>) {
    if let Some(value) = value.and_then(trimmed) {
        *target = Some(value);
    }
}

fn trimmed(value: String) -> Option<String> {
    let next = value.trim();
    if next.is_empty() {
        None
    } else {
        Some(next.to_string())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSnapshot {
    #[serde(default)]
    pub goals: Vec<TrackerItem>,
    #[serde(default)]
    pub tasks: Vec<TrackerItem>,
    #[serde(default)]
    pub facts: Vec<TrackerItem>,
    pub updated_at: String,
}

impl StoredSnapshot {
    pub fn empty(now: &str) -> Self {
        Self {
            goals: Vec::new(),
            tasks: Vec::new(),
            facts: Vec::new(),
            updated_at: now.to_string(),
        }
    }

    pub fn public_snapshot(&self) -> PublicSnapshot {
        PublicSnapshot {
            goals: self.goals.clone(),
            tasks: self.tasks.clone(),
            facts: self.facts.clone(),
            updated_at: self.updated_at.clone(),
            active_draft: self.active_draft().cloned(),
        }
    }

    pub fn active_draft(&self) -> Option<&TrackerItem> {
        self.goals
            .iter()
            .chain(self.tasks.iter())
            .chain(self.facts.iter())
            .find(|item| item.is_drafting() && item.id == "draft-current")
    }

    pub fn find_item(&self, kind: &ItemKind, id: &str) -> Option<&TrackerItem> {
        self.bucket(kind).iter().find(|item| item.id == id)
    }

    pub fn bucket(&self, kind: &ItemKind) -> &[TrackerItem] {
        match kind {
            ItemKind::Goal => &self.goals,
            ItemKind::Task => &self.tasks,
            ItemKind::Fact => &self.facts,
        }
    }

    pub fn bucket_mut(&mut self, kind: &ItemKind) -> &mut Vec<TrackerItem> {
        match kind {
            ItemKind::Goal => &mut self.goals,
            ItemKind::Task => &mut self.tasks,
            ItemKind::Fact => &mut self.facts,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicSnapshot {
    pub goals: Vec<TrackerItem>,
    pub tasks: Vec<TrackerItem>,
    pub facts: Vec<TrackerItem>,
    pub updated_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_draft: Option<TrackerItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SelectionMode {
    Auto,
    Manual,
    Cleared,
}

impl Default for SelectionMode {
    fn default() -> Self {
        Self::Auto
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInput {
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
    #[serde(default)]
    pub selected_object: Option<TrackerItem>,
    #[serde(default)]
    pub selection_mode: SelectionMode,
}

impl Default for SessionInput {
    fn default() -> Self {
        Self {
            history: Vec::new(),
            selected_object: None,
            selection_mode: SelectionMode::Auto,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ChatRequest {
    pub message: String,
    #[serde(flatten)]
    pub session: SessionInput,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ReorderGoalsRequest {
    pub ids: Vec<String>,
    #[serde(flatten)]
    pub session: SessionInput,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionState {
    pub snapshot: PublicSnapshot,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_object: Option<TrackerItem>,
    pub selection_mode: SelectionMode,
    pub history: Vec<HistoryEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub feedback: Option<Feedback>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Feedback {
    pub kind: FeedbackKind,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackKind {
    Info,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolAction {
    pub tool: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ItemKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fields: Option<ItemFields>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pattern: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelReply {
    pub message: String,
    pub needs_follow_up: bool,
    #[serde(default)]
    pub actions: Vec<ToolAction>,
}

#[derive(Debug, Clone)]
pub struct DraftCompletion {
    pub ready: bool,
    pub missing: Vec<String>,
}

impl DraftCompletion {
    pub fn from_item(item: Option<&TrackerItem>) -> Self {
        match item {
            None => Self {
                ready: false,
                missing: vec!["Start by telling me whether this is a task, goal, or fact.".into()],
            },
            Some(item) => match item.kind {
                ItemKind::Task => missing_fields(vec![(
                    item.title.as_ref(),
                    "A task needs a clear action title.",
                )]),
                ItemKind::Goal => missing_fields(vec![
                    (item.title.as_ref(), "A goal needs a clear title."),
                    (
                        item.success_criteria.as_ref(),
                        "A goal needs a measurable success criteria.",
                    ),
                ]),
                ItemKind::Fact => missing_fields(vec![
                    (item.title.as_ref(), "A fact needs a clear title."),
                    (
                        item.project_title.as_ref(),
                        "A fact should be linked to a project.",
                    ),
                ]),
            },
        }
    }
}

fn missing_fields(fields: Vec<(Option<&String>, &'static str)>) -> DraftCompletion {
    let missing = fields
        .into_iter()
        .filter_map(|(value, message)| {
            if value.is_some_and(|value| !value.trim().is_empty()) {
                None
            } else {
                Some(message.to_string())
            }
        })
        .collect::<Vec<_>>();

    DraftCompletion {
        ready: missing.is_empty(),
        missing,
    }
}
