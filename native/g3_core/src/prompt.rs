use chrono::Utc;
use serde_json::{json, Value};

use crate::models::{HistoryEntry, PublicSnapshot, ToolAction, TrackerItem};

pub fn system_instruction(snapshot: &PublicSnapshot, focus_object: Option<&TrackerItem>) -> String {
    format!(
        "You are Goal Studio, an assistant that turns chat into durable goals, tasks, and facts.

Today is {}.

Rules:
- Maintain one active draft object at a time using actions.
- Ask concise follow-up questions when a draft is incomplete.
- Never invent dates, priorities, or success criteria.
- Prefer fact objects for notes, constraints, decisions, and durable project knowledge.
- A task is ready when it has a clear action title.
- A goal is ready when it has a clear title and measurable success criteria.
- A fact is ready when it has a clear title and project_title.
- Use save_draft only when the active draft is ready.
- Use clear_draft when the user abandons the active draft.
- Use search_facts_bm25 for semantic fact lookup and search_facts_grep for exact phrase or token lookup.

Existing tracker state:
{}

Return valid JSON only using the response schema.",
        Utc::now().date_naive(),
        state_summary(snapshot, focus_object)
    )
}

pub fn response_schema() -> Value {
    json!({
      "type": "object",
      "additionalProperties": false,
      "required": ["message", "needs_follow_up", "actions"],
      "properties": {
        "message": { "type": "string" },
        "needs_follow_up": { "type": "boolean" },
        "actions": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["tool"],
            "properties": {
              "tool": {
                "type": "string",
                "enum": [
                  "upsert_draft",
                  "start_new_draft",
                  "save_draft",
                  "clear_draft",
                  "search_facts_bm25",
                  "search_facts_grep"
                ]
              },
              "kind": {
                "type": ["string", "null"],
                "enum": ["goal", "task", "fact", null]
              },
              "fields": {
                "type": ["object", "null"],
                "additionalProperties": false,
                "properties": {
                  "title": { "type": ["string", "null"] },
                  "summary": { "type": ["string", "null"] },
                  "details": { "type": ["string", "null"] },
                  "status": { "type": ["string", "null"] },
                  "success_criteria": { "type": ["string", "null"] },
                  "target_date": { "type": ["string", "null"] },
                  "due_date": { "type": ["string", "null"] },
                  "priority": { "type": ["string", "null"] },
                  "parent_goal_title": { "type": ["string", "null"] },
                  "project_title": { "type": ["string", "null"] }
                }
              },
              "query": { "type": ["string", "null"] },
              "pattern": { "type": ["string", "null"] }
            }
          }
        }
      }
    })
}

pub fn build_contents(history: &[HistoryEntry], latest_user_message: &str) -> Value {
    let mut contents = history
        .iter()
        .map(|entry| {
            json!({
              "role": api_role(&entry.role),
              "parts": [{ "text": entry.content }]
            })
        })
        .collect::<Vec<_>>();

    contents.push(json!({
      "role": "user",
      "parts": [{ "text": latest_user_message }]
    }));

    Value::Array(contents)
}

fn api_role(role: &str) -> &'static str {
    if role == "assistant" {
        "model"
    } else {
        "user"
    }
}

fn state_summary(snapshot: &PublicSnapshot, focus_object: Option<&TrackerItem>) -> String {
    let focused = focus_object
        .map(summary_object)
        .unwrap_or_else(|| "- none".to_string());
    let active = snapshot
        .active_draft
        .as_ref()
        .map(summary_object)
        .unwrap_or_else(|| "- none".to_string());

    format!(
        "Focused object:\n{}\n\nActive draft:\n{}\n\nGoals:\n{}\n\nTasks:\n{}\n\nFacts:\n{}",
        focused,
        active,
        summarize_items(&snapshot.goals),
        summarize_items(&snapshot.tasks),
        summarize_items(&snapshot.facts),
    )
}

fn summary_object(item: &TrackerItem) -> String {
    serde_json::to_string_pretty(item).unwrap_or_else(|_| item.title_or("Untitled"))
}

fn summarize_items(items: &[TrackerItem]) -> String {
    if items.is_empty() {
        return "- none".to_string();
    }

    items
        .iter()
        .take(8)
        .map(|item| {
            let mut parts = vec![format!("id={}", item.id)];
            if let Some(title) = &item.title {
                parts.push(format!("title={title}"));
            }
            if let Some(success) = &item.success_criteria {
                parts.push(format!("success_criteria={success}"));
            }
            if let Some(details) = &item.details {
                parts.push(format!("details={details}"));
            }
            if let Some(status) = &item.status {
                parts.push(format!("status={status}"));
            }
            if let Some(parent) = &item.parent_goal_title {
                parts.push(format!("parent_goal_title={parent}"));
            }
            if let Some(project) = &item.project_title {
                parts.push(format!("project_title={project}"));
            }
            format!("- {}", parts.join(", "))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn results_follow_up_message(user_message: &str, results: &[Value]) -> String {
    format!(
        "Tool results for the original request:\n{}\n\n{}",
        user_message,
        serde_json::to_string_pretty(results).unwrap_or_default()
    )
}

pub fn strip_search_actions(actions: &[ToolAction]) -> Vec<ToolAction> {
    actions
        .iter()
        .filter(|action| {
            !matches!(
                action.tool.as_str(),
                "search_facts_bm25" | "search_facts_grep"
            )
        })
        .cloned()
        .collect()
}
