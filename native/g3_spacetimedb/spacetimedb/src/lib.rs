use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use spacetimedb::{ReducerContext, Table};

#[spacetimedb::table(accessor = tracker_item, public)]
#[derive(Clone)]
pub struct TrackerItemRow {
    #[auto_inc]
    #[primary_key]
    row_id: u64,
    #[unique]
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

#[spacetimedb::table(accessor = workspace_meta, public)]
#[derive(Clone)]
pub struct WorkspaceMeta {
    #[primary_key]
    id: u8,
    updated_at: String,
    next_sort_key: i64,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    role: String,
    content: String,
    follow_up: bool,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug, Default)]
pub struct ItemFieldsInput {
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

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct DraftMutation {
    kind: String,
    fields: ItemFieldsInput,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct ItemRef {
    item_id: String,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct ConversationInput {
    item_id: String,
    conversation: Vec<HistoryEntry>,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct SummaryInput {
    item_id: String,
    summary: String,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct ReorderGoalsInput {
    ids: Vec<String>,
}

#[derive(spacetimedb::SpacetimeType, Clone, Debug)]
pub struct EmptyInput {}

#[spacetimedb::reducer(init)]
pub fn init(ctx: &ReducerContext) {
    let now = now_string(ctx);
    let _ = ensure_meta(ctx, &now);
}

#[spacetimedb::reducer]
pub fn reset_workspace(ctx: &ReducerContext, input: EmptyInput) {
    let _ = input;
    let now = now_string(ctx);
    let row_ids = ctx
        .db
        .tracker_item()
        .iter()
        .map(|item| item.row_id)
        .collect::<Vec<_>>();
    for row_id in row_ids {
        ctx.db.tracker_item().row_id().delete(row_id);
    }

    let mut meta = ensure_meta(ctx, &now);
    meta.updated_at = now;
    meta.next_sort_key = 0;
    ctx.db.workspace_meta().id().update(meta);
}

#[spacetimedb::reducer]
pub fn upsert_draft(ctx: &ReducerContext, input: DraftMutation) -> Result<(), Box<str>> {
    let now = now_string(ctx);
    let kind = normalized_kind(&input.kind)?;

    if let Some(current) = current_draft(ctx) {
        if current.kind != kind {
            archive_current_draft(ctx, &now)?;
            let sort_key = bump_sort_key(ctx, &now);
            ctx.db
                .tracker_item()
                .insert(new_draft_row(kind, input.fields, &now, sort_key));
        } else {
            let mut next = current;
            apply_fields(&mut next, input.fields);
            next.status = "being_drafted".to_string();
            next.item_id = "draft-current".to_string();
            next.updated_at = now.clone();
            ctx.db.tracker_item().row_id().update(next);
            touch_meta(ctx, &now);
        }
    } else {
        let sort_key = bump_sort_key(ctx, &now);
        ctx.db
            .tracker_item()
            .insert(new_draft_row(kind, input.fields, &now, sort_key));
    }

    Ok(())
}

#[spacetimedb::reducer]
pub fn start_draft(ctx: &ReducerContext, input: DraftMutation) -> Result<(), Box<str>> {
    let now = now_string(ctx);
    let kind = normalized_kind(&input.kind)?;
    archive_current_draft(ctx, &now)?;
    let sort_key = bump_sort_key(ctx, &now);
    ctx.db
        .tracker_item()
        .insert(new_draft_row(kind, input.fields, &now, sort_key));
    Ok(())
}

#[spacetimedb::reducer]
pub fn clear_draft(ctx: &ReducerContext, input: EmptyInput) {
    let _ = input;
    let now = now_string(ctx);
    if let Some(current) = current_draft(ctx) {
        ctx.db.tracker_item().row_id().delete(current.row_id);
    }
    touch_meta(ctx, &now);
}

#[spacetimedb::reducer]
pub fn activate_draft(ctx: &ReducerContext, input: ItemRef) -> Result<(), Box<str>> {
    let now = now_string(ctx);
    let Some(mut target) = find_item(ctx, &input.item_id) else {
        return Ok(());
    };

    if target.item_id == "draft-current" {
        target.updated_at = now.clone();
        ctx.db.tracker_item().row_id().update(target);
        touch_meta(ctx, &now);
    } else if target.status == "being_drafted" {
        archive_current_draft(ctx, &now)?;
        target.item_id = "draft-current".to_string();
        target.updated_at = now.clone();
        ctx.db.tracker_item().row_id().update(target);
        touch_meta(ctx, &now);
    }

    Ok(())
}

#[spacetimedb::reducer]
pub fn save_draft(ctx: &ReducerContext, input: EmptyInput) -> Result<(), Box<str>> {
    let _ = input;
    let now = now_string(ctx);
    let Some(mut draft) = current_draft(ctx) else {
        return Err("There is no active draft to save.".into());
    };

    validate_draft(&draft)?;

    draft.item_id = format!("{}-{}", draft.kind, next_uuid(ctx)?);
    draft.status = persisted_status(&draft.kind)?.to_string();
    draft.inserted_at = now.clone();
    draft.updated_at = now.clone();
    draft.sort_key = bump_sort_key(ctx, &now);
    ctx.db.tracker_item().row_id().update(draft);
    Ok(())
}

#[spacetimedb::reducer]
pub fn put_object_conversation(
    ctx: &ReducerContext,
    input: ConversationInput,
) -> Result<(), Box<str>> {
    let now = now_string(ctx);
    let Some(mut item) = find_item(ctx, &input.item_id) else {
        return Ok(());
    };

    item.origin_conversation_json = serde_json::to_string(&input.conversation)
        .map_err(|err| err.to_string().into_boxed_str())?;
    item.updated_at = now.clone();
    ctx.db.tracker_item().row_id().update(item);
    touch_meta(ctx, &now);
    Ok(())
}

#[spacetimedb::reducer]
pub fn put_object_summary(ctx: &ReducerContext, input: SummaryInput) {
    let now = now_string(ctx);
    if let Some(mut item) = find_item(ctx, &input.item_id) {
        item.origin_summary = trimmed_text(input.summary).unwrap_or_default();
        item.updated_at = now.clone();
        ctx.db.tracker_item().row_id().update(item);
        touch_meta(ctx, &now);
    }
}

#[spacetimedb::reducer]
pub fn clear_object_conversation(ctx: &ReducerContext, input: ItemRef) {
    let now = now_string(ctx);
    if let Some(mut item) = find_item(ctx, &input.item_id) {
        item.origin_conversation_json.clear();
        item.origin_summary.clear();
        item.updated_at = now.clone();
        ctx.db.tracker_item().row_id().update(item);
        touch_meta(ctx, &now);
    }
}

#[spacetimedb::reducer]
pub fn reorder_goals(ctx: &ReducerContext, input: ReorderGoalsInput) {
    let now = now_string(ctx);
    let mut changed = false;

    for item_id in input.ids.iter().rev() {
        if let Some(mut item) = find_item(ctx, item_id) {
            if item.kind == "goal" {
                item.sort_key = bump_sort_key(ctx, &now);
                item.updated_at = now.clone();
                ctx.db.tracker_item().row_id().update(item);
                changed = true;
            }
        }
    }

    if !changed {
        touch_meta(ctx, &now);
    }
}

fn current_draft(ctx: &ReducerContext) -> Option<TrackerItemRow> {
    ctx.db
        .tracker_item()
        .iter()
        .find(|item| item.item_id == "draft-current")
        .filter(|item| item.status == "being_drafted")
}

fn find_item(ctx: &ReducerContext, item_id: &str) -> Option<TrackerItemRow> {
    ctx.db
        .tracker_item()
        .iter()
        .find(|item| item.item_id == item_id)
}

fn archive_current_draft(ctx: &ReducerContext, now: &str) -> Result<(), Box<str>> {
    if let Some(mut current) = current_draft(ctx) {
        current.item_id = format!("draft-{}-{}", current.kind, next_uuid(ctx)?);
        current.updated_at = now.to_string();
        ctx.db.tracker_item().row_id().update(current);
    }

    Ok(())
}

fn validate_draft(draft: &TrackerItemRow) -> Result<(), Box<str>> {
    let mut missing = Vec::new();
    match draft.kind.as_str() {
        "task" => {
            if draft.title.trim().is_empty() {
                missing.push("A task needs a clear action title.");
            }
        }
        "goal" => {
            if draft.title.trim().is_empty() {
                missing.push("A goal needs a clear title.");
            }
            if draft.success_criteria.trim().is_empty() {
                missing.push("A goal needs a measurable success criteria.");
            }
        }
        "fact" => {
            if draft.title.trim().is_empty() {
                missing.push("A fact needs a clear title.");
            }
            if draft.project_title.trim().is_empty() {
                missing.push("A fact should be linked to a project.");
            }
        }
        _ => missing.push("Start by telling me whether this is a task, goal, or fact."),
    }

    if missing.is_empty() {
        Ok(())
    } else {
        Err(missing.join(" ").into_boxed_str())
    }
}

fn new_draft_row(kind: &str, fields: ItemFieldsInput, now: &str, sort_key: i64) -> TrackerItemRow {
    let mut row = TrackerItemRow {
        row_id: 0,
        item_id: "draft-current".to_string(),
        kind: kind.to_string(),
        sort_key,
        title: String::new(),
        summary: String::new(),
        details: String::new(),
        status: "being_drafted".to_string(),
        success_criteria: String::new(),
        target_date: String::new(),
        due_date: String::new(),
        priority: String::new(),
        parent_goal_title: String::new(),
        project_title: String::new(),
        origin_conversation_json: String::new(),
        origin_summary: String::new(),
        inserted_at: String::new(),
        updated_at: now.to_string(),
    };
    apply_fields(&mut row, fields);
    row.status = "being_drafted".to_string();
    row.item_id = "draft-current".to_string();
    row.updated_at = now.to_string();
    row
}

fn apply_fields(row: &mut TrackerItemRow, fields: ItemFieldsInput) {
    apply_text(&mut row.title, fields.title);
    apply_text(&mut row.summary, fields.summary);
    apply_text(&mut row.details, fields.details);
    apply_text(&mut row.status, fields.status);
    apply_text(&mut row.success_criteria, fields.success_criteria);
    apply_text(&mut row.target_date, fields.target_date);
    apply_text(&mut row.due_date, fields.due_date);
    apply_text(&mut row.priority, fields.priority);
    apply_text(&mut row.parent_goal_title, fields.parent_goal_title);
    apply_text(&mut row.project_title, fields.project_title);
}

fn apply_text(target: &mut String, next: String) {
    if let Some(value) = trimmed_text(next) {
        *target = value;
    }
}

fn trimmed_text(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn persisted_status(kind: &str) -> Result<&'static str, Box<str>> {
    match kind {
        "goal" => Ok("draft"),
        "task" => Ok("planned"),
        "fact" => Ok("known"),
        _ => Err(format!("Unsupported item kind `{kind}`.").into_boxed_str()),
    }
}

fn normalized_kind(kind: &str) -> Result<&'static str, Box<str>> {
    match kind {
        "goal" => Ok("goal"),
        "task" => Ok("task"),
        "fact" => Ok("fact"),
        _ => Err(format!("Unsupported item kind `{kind}`.").into_boxed_str()),
    }
}

fn ensure_meta(ctx: &ReducerContext, now: &str) -> WorkspaceMeta {
    if let Some(meta) = ctx.db.workspace_meta().id().find(1) {
        meta
    } else {
        let meta = WorkspaceMeta {
            id: 1,
            updated_at: now.to_string(),
            next_sort_key: 0,
        };
        ctx.db.workspace_meta().insert(meta.clone());
        meta
    }
}

fn touch_meta(ctx: &ReducerContext, now: &str) {
    let mut meta = ensure_meta(ctx, now);
    meta.updated_at = now.to_string();
    ctx.db.workspace_meta().id().update(meta);
}

fn bump_sort_key(ctx: &ReducerContext, now: &str) -> i64 {
    let mut meta = ensure_meta(ctx, now);
    meta.next_sort_key += 1;
    meta.updated_at = now.to_string();
    let next = meta.next_sort_key;
    ctx.db.workspace_meta().id().update(meta);
    next
}

fn next_uuid(ctx: &ReducerContext) -> Result<String, Box<str>> {
    ctx.new_uuid_v7()
        .map(|uuid| uuid.to_string())
        .map_err(|err| err.to_string().into_boxed_str())
}

fn now_string(ctx: &ReducerContext) -> String {
    chrono::DateTime::<Utc>::from_timestamp_micros(ctx.timestamp.to_micros_since_unix_epoch())
        .map(|timestamp| timestamp.to_rfc3339_opts(SecondsFormat::Secs, true))
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}
