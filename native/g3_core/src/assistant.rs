use std::{fs, path::PathBuf};

use anyhow::{anyhow, Context, Result};
use regex::Regex;
use serde::Deserialize;
use serde_json::{json, Value};
use tracing::warn;

use crate::{
    fact_search,
    models::{
        DraftCompletion, HistoryEntry, ItemFields, ItemKind, ModelReply, PublicSnapshot,
        ToolAction, TrackerItem,
    },
    prompt,
};

const GEMINI_ENDPOINT: &str = "https://generativelanguage.googleapis.com/v1beta/models";

pub struct AssistantEngine {
    gemini: Option<GeminiClient>,
}

impl AssistantEngine {
    pub fn from_config_path(path: impl Into<PathBuf>) -> Self {
        Self {
            gemini: GeminiClient::load(path.into()).ok(),
        }
    }

    pub async fn respond(
        &self,
        user_message: &str,
        snapshot: &PublicSnapshot,
        history: &[HistoryEntry],
        focus_object: Option<&TrackerItem>,
    ) -> Result<ModelReply> {
        if let Some(gemini) = &self.gemini {
            match gemini
                .respond(user_message, snapshot, history, focus_object)
                .await
            {
                Ok(reply) => return Ok(reply),
                Err(error) => warn!("gemini assistant failed, falling back to rules: {error:#}"),
            }
        }

        Ok(rule_based_reply(user_message, snapshot, focus_object))
    }

    pub async fn summarize(
        &self,
        conversation: &[HistoryEntry],
        item: Option<&TrackerItem>,
    ) -> Result<String> {
        if let Some(gemini) = &self.gemini {
            match gemini.summarize(conversation, item).await {
                Ok(summary) => return Ok(summary),
                Err(error) => warn!("gemini summarizer failed, falling back to rules: {error:#}"),
            }
        }

        Ok(fallback_summary(conversation, item))
    }
}

#[derive(Debug, Deserialize)]
struct GeminiConfigFile {
    api_key: String,
    model: String,
    #[serde(default)]
    fallback_model: Option<String>,
}

struct GeminiClient {
    client: reqwest::Client,
    api_key: String,
    model: String,
    fallback_model: Option<String>,
}

impl GeminiClient {
    fn load(path: PathBuf) -> Result<Self> {
        let encoded = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let config: GeminiConfigFile = serde_json::from_str(&encoded)
            .with_context(|| format!("failed to decode {}", path.display()))?;

        if config.api_key.trim().is_empty() {
            return Err(anyhow!("gemini api_key is blank"));
        }
        if config.model.trim().is_empty() {
            return Err(anyhow!("gemini model is blank"));
        }

        Ok(Self {
            client: reqwest::Client::builder()
                .connect_timeout(std::time::Duration::from_secs(15))
                .timeout(std::time::Duration::from_secs(90))
                .build()?,
            api_key: config.api_key,
            model: config.model,
            fallback_model: config
                .fallback_model
                .filter(|value| !value.trim().is_empty()),
        })
    }

    async fn respond(
        &self,
        user_message: &str,
        snapshot: &PublicSnapshot,
        history: &[HistoryEntry],
        focus_object: Option<&TrackerItem>,
    ) -> Result<ModelReply> {
        let initial = self
            .request_json(
                &prompt::system_instruction(snapshot, focus_object),
                prompt::build_contents(history, user_message),
                prompt::response_schema(),
            )
            .await?;

        let mut reply: ModelReply = serde_json::from_value(initial)?;

        if reply.actions.iter().any(search_action) {
            let tool_results = execute_search_actions(&reply.actions, &snapshot.facts);
            let mut search_history = history.to_vec();
            search_history.push(HistoryEntry {
                role: "user".to_string(),
                content: user_message.to_string(),
                follow_up: false,
            });
            if !reply.message.trim().is_empty() {
                search_history.push(HistoryEntry {
                    role: "assistant".to_string(),
                    content: reply.message.clone(),
                    follow_up: reply.needs_follow_up,
                });
            }
            search_history.push(HistoryEntry {
                role: "user".to_string(),
                content: prompt::results_follow_up_message(user_message, &tool_results),
                follow_up: false,
            });

            let follow_up = self
                .request_json(
                    &prompt::system_instruction(snapshot, focus_object),
                    prompt::build_contents(
                        &search_history,
                        "Use the fact search results above to answer the original request. Do not call search again unless it is still necessary.",
                    ),
                    prompt::response_schema(),
                )
                .await?;

            let mut follow_up_reply: ModelReply = serde_json::from_value(follow_up)?;
            follow_up_reply.actions = prompt::strip_search_actions(&follow_up_reply.actions);
            reply = follow_up_reply;
        }

        Ok(reply)
    }

    async fn summarize(
        &self,
        conversation: &[HistoryEntry],
        item: Option<&TrackerItem>,
    ) -> Result<String> {
        if conversation.is_empty() {
            return Err(anyhow!("conversation is empty"));
        }

        let object_label = item
            .and_then(|item| item.title.clone())
            .unwrap_or_else(|| "the selected object".to_string());

        let history = conversation
            .iter()
            .map(|entry| {
                json!({
                    "role": if entry.role == "assistant" { "model" } else { "user" },
                    "parts": [{ "text": entry.content }]
                })
            })
            .collect::<Vec<_>>();

        let value = self
            .request_json(
                &format!(
                    "You summarize tracker conversations. Summarize the discussion about {} in 1-2 concise sentences. Mention key constraints, dates, or priorities when present.",
                    object_label
                ),
                Value::Array(history),
                json!({
                  "type": "object",
                  "additionalProperties": false,
                  "required": ["summary"],
                  "properties": {
                    "summary": { "type": "string" }
                  }
                }),
            )
            .await?;

        value
            .get("summary")
            .and_then(Value::as_str)
            .map(|summary| summary.trim().to_string())
            .filter(|summary| !summary.is_empty())
            .ok_or_else(|| anyhow!("gemini summary payload was missing summary"))
    }

    async fn request_json(
        &self,
        system_instruction: &str,
        contents: Value,
        response_schema: Value,
    ) -> Result<Value> {
        let request_body = json!({
            "systemInstruction": { "parts": [{ "text": system_instruction }] },
            "contents": contents,
            "generationConfig": {
                "temperature": 0.1,
                "responseMimeType": "application/json",
                "responseJsonSchema": response_schema
            }
        });

        let mut models = vec![self.model.clone()];
        if let Some(fallback) = &self.fallback_model {
            if fallback != &self.model {
                models.push(fallback.clone());
            }
        }

        let mut last_error = None;

        for model in models {
            match self.try_request_model(&model, &request_body).await {
                Ok(value) => return Ok(value),
                Err(error) => last_error = Some(error),
            }
        }

        Err(last_error.unwrap_or_else(|| anyhow!("no Gemini model candidates succeeded")))
    }

    async fn try_request_model(&self, model: &str, request_body: &Value) -> Result<Value> {
        let response = self
            .client
            .post(format!("{GEMINI_ENDPOINT}/{model}:generateContent"))
            .header("x-goog-api-key", &self.api_key)
            .json(request_body)
            .send()
            .await?;

        let status = response.status();
        let body: Value = response.json().await?;

        if !status.is_success() {
            return Err(anyhow!("Gemini request failed with {}: {}", status, body));
        }

        let payload = body
            .get("candidates")
            .and_then(Value::as_array)
            .and_then(|candidates| candidates.first())
            .and_then(|candidate| candidate.get("content"))
            .and_then(|content| content.get("parts"))
            .and_then(Value::as_array)
            .and_then(|parts| parts.iter().find_map(|part| part.get("text")))
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("Gemini response was missing text content"))?;

        serde_json::from_str(payload).with_context(|| "Gemini payload was not valid JSON")
    }
}

fn search_action(action: &ToolAction) -> bool {
    matches!(
        action.tool.as_str(),
        "search_facts_bm25" | "search_facts_grep"
    )
}

fn execute_search_actions(actions: &[ToolAction], facts: &[TrackerItem]) -> Vec<Value> {
    actions
        .iter()
        .filter_map(|action| match action.tool.as_str() {
            "search_facts_bm25" => action.query.as_deref().map(|query| {
                json!({
                    "tool": "search_facts_bm25",
                    "query": query,
                    "results": fact_search::bm25(query, facts, 5)
                })
            }),
            "search_facts_grep" => action.pattern.as_deref().map(|pattern| {
                json!({
                    "tool": "search_facts_grep",
                    "pattern": pattern,
                    "results": fact_search::grep(pattern, facts, 5)
                })
            }),
            _ => None,
        })
        .collect()
}

fn rule_based_reply(
    user_message: &str,
    snapshot: &PublicSnapshot,
    focus_object: Option<&TrackerItem>,
) -> ModelReply {
    let message = user_message.trim();
    let active_draft = snapshot.active_draft.as_ref();

    if abandon_message(message) && active_draft.is_some() {
        return ModelReply {
            message: "Cleared the current draft.".to_string(),
            needs_follow_up: false,
            actions: vec![ToolAction {
                tool: "clear_draft".to_string(),
                kind: None,
                fields: None,
                query: None,
                pattern: None,
            }],
        };
    }

    if let Some(reply) = fact_search_reply(message, snapshot) {
        return reply;
    }

    let kind = infer_kind(message, active_draft);
    let Some(kind) = kind else {
        return ModelReply {
            message:
                "Tell me whether this should become a goal, task, or fact, or give me a clearer action."
                    .to_string(),
            needs_follow_up: true,
            actions: Vec::new(),
        };
    };

    let mut fields = infer_fields(message, &kind, active_draft, snapshot, focus_object);
    if fields.is_empty() && active_draft.is_some() {
        fields.summary = Some(message.to_string());
    }

    let action_tool = if active_draft.is_some_and(|draft| draft.kind == kind) {
        "upsert_draft"
    } else if active_draft.is_some() {
        "start_new_draft"
    } else {
        "upsert_draft"
    };

    let mut actions = if fields.is_empty() {
        Vec::new()
    } else {
        vec![ToolAction {
            tool: action_tool.to_string(),
            kind: Some(kind.clone()),
            fields: Some(fields.clone()),
            query: None,
            pattern: None,
        }]
    };

    let projected = projected_draft(&kind, active_draft, &fields);
    let completion = DraftCompletion::from_item(Some(&projected));

    if completion.ready {
        actions.push(ToolAction {
            tool: "save_draft".to_string(),
            kind: None,
            fields: None,
            query: None,
            pattern: None,
        });

        let confirmation = match kind {
            ItemKind::Goal => "Saved that goal.",
            ItemKind::Task => "Saved that task.",
            ItemKind::Fact => "Saved that fact.",
        };

        ModelReply {
            message: confirmation.to_string(),
            needs_follow_up: false,
            actions,
        }
    } else {
        let follow_up = completion
            .missing
            .first()
            .cloned()
            .unwrap_or_else(|| "Tell me a bit more.".to_string());

        ModelReply {
            message: follow_up,
            needs_follow_up: true,
            actions,
        }
    }
}

fn fallback_summary(conversation: &[HistoryEntry], item: Option<&TrackerItem>) -> String {
    let title = item
        .and_then(|item| item.title.clone())
        .unwrap_or_else(|| "The discussion".to_string());

    let first_user = conversation
        .iter()
        .find(|entry| entry.role == "user")
        .map(|entry| entry.content.clone())
        .unwrap_or_default();

    let last_user = conversation
        .iter()
        .rev()
        .find(|entry| entry.role == "user")
        .map(|entry| entry.content.clone())
        .unwrap_or_default();

    if first_user == last_user || last_user.is_empty() {
        format!("{title}: {}", truncate(&first_user, 180))
    } else {
        format!(
            "{title}: started with {} Later, it was refined to {}",
            truncate(&first_user, 90),
            truncate(&last_user, 90)
        )
    }
}

fn abandon_message(message: &str) -> bool {
    let lower = message.to_lowercase();
    lower.contains("never mind") || lower.contains("drop that") || lower.contains("forget it")
}

fn fact_search_reply(message: &str, snapshot: &PublicSnapshot) -> Option<ModelReply> {
    let lower = message.to_lowercase();
    let facts = &snapshot.facts;

    if let Some(pattern) = message
        .strip_prefix("Search facts for ")
        .or_else(|| message.strip_prefix("search facts for "))
    {
        let results = fact_search::grep(pattern.trim_matches('/').trim(), facts, 5);
        return Some(search_reply(results));
    }

    if lower.contains("what facts") || lower.starts_with("find facts") {
        let query = message
            .split_once("about")
            .map(|(_, tail)| tail.trim())
            .filter(|query| !query.is_empty())
            .unwrap_or(message);
        let results = fact_search::bm25(query, facts, 5);
        return Some(search_reply(results));
    }

    None
}

fn search_reply(results: Vec<fact_search::SearchResult>) -> ModelReply {
    if results.is_empty() {
        return ModelReply {
            message: "I couldn't find any matching saved facts.".to_string(),
            needs_follow_up: false,
            actions: Vec::new(),
        };
    }

    let lines = results
        .into_iter()
        .map(|result| {
            let title = result.title.unwrap_or_else(|| "Untitled fact".to_string());
            let project = result
                .project_title
                .map(|project| format!(" [{}]", project))
                .unwrap_or_default();
            format!("- {title}{project}: {}", result.snippet)
        })
        .collect::<Vec<_>>();

    ModelReply {
        message: format!("Here are the most relevant facts:\n{}", lines.join("\n")),
        needs_follow_up: false,
        actions: Vec::new(),
    }
}

fn infer_kind(message: &str, active_draft: Option<&TrackerItem>) -> Option<ItemKind> {
    if let Some(kind) = active_draft.map(|item| item.kind.clone()) {
        if !starts_new_item(message) {
            return Some(kind);
        }
    }

    let lower = message.trim().to_lowercase();
    if lower.starts_with("fact:")
        || lower.starts_with("note:")
        || lower.starts_with("constraint:")
        || lower.starts_with("decision:")
        || lower.starts_with("remember ")
    {
        Some(ItemKind::Fact)
    } else if Regex::new(r"^(create|add|make)\s+(a\s+)?task\b")
        .unwrap()
        .is_match(&lower)
    {
        Some(ItemKind::Task)
    } else if lower.starts_with("i want to") || lower.starts_with("my goal is to") {
        Some(ItemKind::Goal)
    } else {
        active_draft.map(|item| item.kind.clone())
    }
}

fn starts_new_item(message: &str) -> bool {
    let lower = message.trim().to_lowercase();
    lower.starts_with("fact:")
        || lower.starts_with("note:")
        || lower.starts_with("constraint:")
        || lower.starts_with("decision:")
        || lower.starts_with("remember ")
        || lower.starts_with("i want to")
        || lower.starts_with("my goal is to")
        || Regex::new(r"^(create|add|make)\s+(a\s+)?task\b")
            .unwrap()
            .is_match(&lower)
}

fn infer_fields(
    message: &str,
    kind: &ItemKind,
    active_draft: Option<&TrackerItem>,
    snapshot: &PublicSnapshot,
    focus_object: Option<&TrackerItem>,
) -> ItemFields {
    let mut fields = ItemFields::default();
    let trimmed = message.trim();

    match kind {
        ItemKind::Goal => {
            fields.title = infer_goal_title(trimmed)
                .or_else(|| active_draft.and_then(|item| item.title.clone()));
            fields.target_date = infer_date(trimmed);
            fields.success_criteria = infer_goal_success(trimmed, active_draft);
        }
        ItemKind::Task => {
            fields.title = infer_task_title(trimmed)
                .or_else(|| active_draft.and_then(|item| item.title.clone()));
            fields.due_date = infer_date(trimmed);
            fields.priority = infer_priority(trimmed);
            fields.parent_goal_title =
                infer_goal_link(snapshot, focus_object, active_draft, trimmed, false);
        }
        ItemKind::Fact => {
            fields.title = infer_fact_title(trimmed)
                .or_else(|| active_draft.and_then(|item| item.title.clone()));
            fields.details = Some(trimmed.to_string());
            fields.project_title =
                infer_goal_link(snapshot, focus_object, active_draft, trimmed, true);
        }
    }

    if fields.summary.is_none() && fields.details.is_none() && kind != &ItemKind::Fact {
        if let Some(detail) = infer_detail(trimmed, kind) {
            fields.details = Some(detail);
        }
    }

    fields
}

fn infer_goal_title(message: &str) -> Option<String> {
    let stripped = message
        .strip_prefix("I want to ")
        .or_else(|| message.strip_prefix("i want to "))
        .or_else(|| message.strip_prefix("My goal is to "))
        .or_else(|| message.strip_prefix("my goal is to "))
        .unwrap_or(message);

    clean_title(&strip_trailing_date(stripped))
}

fn infer_task_title(message: &str) -> Option<String> {
    let regex = Regex::new(
        r"(?i)^(?:create|add|make)\s+(?:a\s+)?task\s+to\s+(.+?)(?:\s+by\s+\d{4}-\d{2}-\d{2}.*)?$",
    )
    .unwrap();

    if let Some(captures) = regex.captures(message) {
        return captures
            .get(1)
            .and_then(|value| clean_title(value.as_str()));
    }

    clean_title(&strip_trailing_date(message))
}

fn infer_fact_title(message: &str) -> Option<String> {
    let cleaned = Regex::new(r"(?i)^(fact|note|constraint|decision)\s*:\s*")
        .unwrap()
        .replace(message, "")
        .to_string();

    clean_title(cleaned.trim())
}

fn clean_title(value: &str) -> Option<String> {
    let value = value.trim().trim_end_matches('.').trim();
    if value.is_empty() {
        None
    } else {
        Some(uppercase_first(value))
    }
}

fn uppercase_first(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn infer_goal_success(message: &str, active_draft: Option<&TrackerItem>) -> Option<String> {
    let lower = message.to_lowercase();
    if lower.contains("success means")
        || lower.contains("success looks like")
        || lower.contains("success criteria")
    {
        return Some(message.to_string());
    }

    if Regex::new(r"(?i)\bunder\b").unwrap().is_match(message) && active_draft.is_some() {
        return Some(message.to_string());
    }

    if active_draft
        .is_some_and(|draft| draft.kind == ItemKind::Goal && draft.success_criteria.is_none())
        && !starts_new_item(message)
    {
        return Some(message.to_string());
    }

    None
}

fn infer_detail(message: &str, kind: &ItemKind) -> Option<String> {
    match kind {
        ItemKind::Goal if message.len() > 50 => Some(message.to_string()),
        ItemKind::Task if message.len() > 50 => Some(message.to_string()),
        _ => None,
    }
}

fn infer_priority(message: &str) -> Option<String> {
    let lower = message.to_lowercase();
    ["high", "medium", "low"]
        .into_iter()
        .find(|priority| lower.contains(priority))
        .map(ToString::to_string)
}

fn infer_goal_link(
    snapshot: &PublicSnapshot,
    focus_object: Option<&TrackerItem>,
    active_draft: Option<&TrackerItem>,
    message: &str,
    for_fact: bool,
) -> Option<String> {
    if let Some(goal) = focus_object.filter(|item| item.kind == ItemKind::Goal) {
        return goal.title.clone();
    }

    if let Some(current) = active_draft {
        if for_fact {
            if let Some(project) = &current.project_title {
                return Some(project.clone());
            }
        } else if let Some(parent) = &current.parent_goal_title {
            return Some(parent.clone());
        }
    }

    if snapshot.goals.len() == 1 {
        return snapshot.goals.first().and_then(|goal| goal.title.clone());
    }

    let lower = message.to_lowercase();
    snapshot
        .goals
        .iter()
        .find(|goal| {
            goal.title
                .as_ref()
                .is_some_and(|title| lower.contains(&title.to_lowercase()))
        })
        .and_then(|goal| goal.title.clone())
}

fn infer_date(message: &str) -> Option<String> {
    Regex::new(r"\b\d{4}-\d{2}-\d{2}\b")
        .unwrap()
        .find(message)
        .map(|value| value.as_str().to_string())
        .or_else(|| {
            Regex::new(r"\b\d{4}-\d{2}\b")
                .unwrap()
                .find(message)
                .map(|value| value.as_str().to_string())
        })
}

fn strip_trailing_date(message: &str) -> String {
    Regex::new(r"(?i)\s+by\s+\d{4}-\d{2}(?:-\d{2})?.*$")
        .unwrap()
        .replace(message, "")
        .into_owned()
}

fn projected_draft(
    kind: &ItemKind,
    active_draft: Option<&TrackerItem>,
    fields: &ItemFields,
) -> TrackerItem {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let mut item = active_draft
        .cloned()
        .filter(|draft| draft.kind == *kind)
        .unwrap_or_else(|| TrackerItem::new_draft(kind.clone(), ItemFields::default(), &now));
    item.apply_fields(fields.clone(), &now);
    item.kind = kind.clone();
    item
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        value.to_string()
    } else {
        format!(
            "{}...",
            value
                .chars()
                .take(max_chars.saturating_sub(3))
                .collect::<String>()
        )
    }
}
