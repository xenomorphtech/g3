use std::sync::Arc;

use thiserror::Error;

use crate::{
    assistant::AssistantEngine,
    models::{
        ChatRequest, Feedback, FeedbackKind, HistoryEntry, ItemFields, ItemKind, PublicSnapshot,
        ReorderGoalsRequest, SelectionMode, SessionInput, SessionState, ToolAction, TrackerItem,
    },
    store::{SaveDraftError, WorkspaceStore},
};

#[derive(Clone)]
pub struct TrackerService {
    store: Arc<WorkspaceStore>,
    assistant: Arc<AssistantEngine>,
}

#[derive(Debug, Error)]
pub enum ServiceError {
    #[error("{0}")]
    BadRequest(String),
    #[error("{0}")]
    NotFound(String),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl TrackerService {
    pub fn new(store: WorkspaceStore, assistant: AssistantEngine) -> Self {
        Self {
            store: Arc::new(store),
            assistant: Arc::new(assistant),
        }
    }

    pub fn session(&self) -> SessionState {
        self.sync_state(self.store.snapshot(), None, SelectionMode::Auto, None)
    }

    pub fn clear_selection(&self) -> SessionState {
        self.sync_state(self.store.snapshot(), None, SelectionMode::Cleared, None)
    }

    pub fn select_object(&self, kind: ItemKind, id: String) -> Result<SessionState, ServiceError> {
        let snapshot = self.store.snapshot();
        let selected = find_object(&snapshot, &kind, &id)
            .ok_or_else(|| ServiceError::NotFound("Object not found.".to_string()))?;

        let next_snapshot = if selected.is_drafting() {
            self.store.activate_draft(&kind, &id)?
        } else {
            snapshot
        };

        Ok(self.sync_state(next_snapshot, Some(selected), SelectionMode::Manual, None))
    }

    pub async fn send_message(&self, request: ChatRequest) -> Result<SessionState, ServiceError> {
        let message = request.message.trim();
        if message.is_empty() {
            return Err(ServiceError::BadRequest(
                "Enter a message before sending it.".to_string(),
            ));
        }

        let history = trim_history(request.session.history);
        let snapshot = self.store.snapshot();
        let selected = resolve_selected_object(
            &snapshot,
            request.session.selected_object.as_ref(),
            &request.session.selection_mode,
        );

        if selected.as_ref().is_some_and(|item| item.is_drafting()) {
            let kind = selected.as_ref().unwrap().kind.clone();
            let id = selected.as_ref().unwrap().id.clone();
            let _ = self.store.activate_draft(&kind, &id)?;
        }

        let fresh_snapshot = self.store.snapshot();
        let fresh_selected = resolve_selected_object(
            &fresh_snapshot,
            selected.as_ref(),
            &request.session.selection_mode,
        );

        let reply = self
            .assistant
            .respond(message, &fresh_snapshot, &history, fresh_selected.as_ref())
            .await?;

        self.apply_actions(&reply.actions, fresh_selected.as_ref())?;

        let next_history = trim_history(
            history
                .into_iter()
                .chain([
                    HistoryEntry {
                        role: "user".to_string(),
                        content: message.to_string(),
                        follow_up: false,
                    },
                    HistoryEntry {
                        role: "assistant".to_string(),
                        content: reply.message.clone(),
                        follow_up: reply.needs_follow_up,
                    },
                ])
                .collect(),
        );

        let after_actions = self.store.snapshot();
        let (snapshot, selected_object, selection_mode) = self.persist_origin_conversation(
            after_actions,
            &reply.actions,
            fresh_selected.as_ref(),
            request.session.selection_mode,
            next_history,
        )?;

        Ok(self.sync_state(snapshot, selected_object, selection_mode, None))
    }

    pub fn save_draft(&self, input: SessionInput) -> Result<SessionState, ServiceError> {
        match self.store.save_draft() {
            Ok(snapshot) => Ok(self.sync_state(
                snapshot,
                input.selected_object,
                input.selection_mode,
                Some(feedback(FeedbackKind::Info, "Draft saved.")),
            )),
            Err(SaveDraftError::MissingDraft) => Err(ServiceError::BadRequest(
                "There isn’t a ready draft to save yet.".to_string(),
            )),
            Err(SaveDraftError::Incomplete(message)) => Err(ServiceError::BadRequest(message)),
            Err(SaveDraftError::Io(error)) => Err(ServiceError::Internal(error)),
        }
    }

    pub fn clear_draft(&self, input: SessionInput) -> Result<SessionState, ServiceError> {
        let snapshot = self.store.clear_draft()?;
        Ok(self.sync_state(
            snapshot,
            input.selected_object,
            input.selection_mode,
            Some(feedback(FeedbackKind::Info, "Draft cleared.")),
        ))
    }

    pub async fn summarize_conversation(
        &self,
        input: SessionInput,
    ) -> Result<SessionState, ServiceError> {
        let snapshot = self.store.snapshot();
        let selected = resolve_selected_object(
            &snapshot,
            input.selected_object.as_ref(),
            &input.selection_mode,
        );
        let Some(selected) = selected else {
            return Err(ServiceError::BadRequest(
                "There isn’t a saved conversation to summarize yet.".to_string(),
            ));
        };

        let history = selected.origin_conversation.clone().unwrap_or_default();
        if history.is_empty() {
            return Err(ServiceError::BadRequest(
                "There isn’t a saved conversation to summarize yet.".to_string(),
            ));
        }

        let summary = self.assistant.summarize(&history, Some(&selected)).await?;
        let snapshot = self
            .store
            .put_object_summary(&selected.kind, &selected.id, summary)?;

        Ok(self.sync_state(
            snapshot,
            Some(selected),
            input.selection_mode,
            Some(feedback(FeedbackKind::Info, "Conversation summarized.")),
        ))
    }

    pub fn clear_conversation(&self, input: SessionInput) -> Result<SessionState, ServiceError> {
        let snapshot = self.store.snapshot();
        let selected = resolve_selected_object(
            &snapshot,
            input.selected_object.as_ref(),
            &input.selection_mode,
        );
        let Some(selected) = selected else {
            return Err(ServiceError::BadRequest(
                "Select an object first.".to_string(),
            ));
        };

        let snapshot = self
            .store
            .clear_object_conversation(&selected.kind, &selected.id)?;

        Ok(self.sync_state(
            snapshot,
            Some(selected),
            input.selection_mode,
            Some(feedback(FeedbackKind::Info, "Conversation cleared.")),
        ))
    }

    pub fn reorder_goals(
        &self,
        request: ReorderGoalsRequest,
    ) -> Result<SessionState, ServiceError> {
        let snapshot = self.store.reorder_goals(&request.ids)?;
        Ok(self.sync_state(
            snapshot,
            request.session.selected_object,
            request.session.selection_mode,
            None,
        ))
    }

    fn apply_actions(
        &self,
        actions: &[ToolAction],
        focus_object: Option<&TrackerItem>,
    ) -> Result<(), ServiceError> {
        for action in actions {
            match action.tool.as_str() {
                "upsert_draft" => {
                    let kind = action.kind.clone().ok_or_else(|| {
                        ServiceError::BadRequest("Missing action kind.".to_string())
                    })?;
                    let fields = action.fields.clone().unwrap_or_default();
                    self.store.upsert_draft(kind, fields)?;
                }
                "start_new_draft" => {
                    let kind = action.kind.clone().ok_or_else(|| {
                        ServiceError::BadRequest("Missing action kind.".to_string())
                    })?;
                    let fields = action.fields.clone().unwrap_or_default();
                    self.store.start_draft(kind, fields)?;
                }
                "save_draft" => {
                    if let Some((kind, fields)) = action
                        .kind
                        .clone()
                        .zip(action.fields.clone())
                        .filter(|(_, fields)| !fields.is_empty())
                    {
                        self.store.upsert_draft(kind, fields)?;
                    }

                    if let Some(active_draft) = self.store.snapshot().active_draft {
                        if active_draft.kind == ItemKind::Task
                            && active_draft.parent_goal_title.is_none()
                        {
                            if let Some(parent) =
                                infer_focus_goal(focus_object, &self.store.snapshot())
                            {
                                self.store.upsert_draft(
                                    ItemKind::Task,
                                    ItemFields {
                                        parent_goal_title: Some(parent),
                                        ..ItemFields::default()
                                    },
                                )?;
                            }
                        }

                        if active_draft.kind == ItemKind::Fact
                            && active_draft.project_title.is_none()
                        {
                            if let Some(project) =
                                infer_focus_goal(focus_object, &self.store.snapshot())
                            {
                                self.store.upsert_draft(
                                    ItemKind::Fact,
                                    ItemFields {
                                        project_title: Some(project),
                                        ..ItemFields::default()
                                    },
                                )?;
                            }
                        }
                    }

                    match self.store.save_draft() {
                        Ok(_) | Err(SaveDraftError::MissingDraft) => {}
                        Err(SaveDraftError::Incomplete(_)) => {}
                        Err(SaveDraftError::Io(error)) => {
                            return Err(ServiceError::Internal(error))
                        }
                    }
                }
                "clear_draft" => {
                    self.store.clear_draft()?;
                }
                "search_facts_bm25" | "search_facts_grep" => {}
                _ => {}
            }
        }

        Ok(())
    }

    fn persist_origin_conversation(
        &self,
        snapshot: PublicSnapshot,
        actions: &[ToolAction],
        selected_object: Option<&TrackerItem>,
        selection_mode: SelectionMode,
        history: Vec<HistoryEntry>,
    ) -> Result<(PublicSnapshot, Option<TrackerItem>, SelectionMode), ServiceError> {
        let Some(target) = conversation_target(&snapshot, actions, selected_object) else {
            return Ok((snapshot, selected_object.cloned(), selection_mode));
        };

        let updated_snapshot =
            self.store
                .put_object_conversation(&target.kind, &target.id, history)?;
        let resolved_target = find_same_object(&updated_snapshot, &target);

        if selection_mode == SelectionMode::Cleared {
            Ok((updated_snapshot, None, SelectionMode::Cleared))
        } else {
            Ok((updated_snapshot, resolved_target, SelectionMode::Manual))
        }
    }

    fn sync_state(
        &self,
        snapshot: PublicSnapshot,
        selected_object: Option<TrackerItem>,
        selection_mode: SelectionMode,
        feedback: Option<Feedback>,
    ) -> SessionState {
        let resolved_selected =
            resolve_selected_object(&snapshot, selected_object.as_ref(), &selection_mode);
        let history = resolved_selected
            .as_ref()
            .and_then(|item| item.origin_conversation.clone())
            .unwrap_or_default();

        SessionState {
            snapshot,
            selected_object: resolved_selected,
            selection_mode,
            history,
            feedback,
        }
    }
}

fn feedback(kind: FeedbackKind, message: &str) -> Feedback {
    Feedback {
        kind,
        message: message.to_string(),
    }
}

fn resolve_selected_object(
    snapshot: &PublicSnapshot,
    selected_object: Option<&TrackerItem>,
    selection_mode: &SelectionMode,
) -> Option<TrackerItem> {
    match selection_mode {
        SelectionMode::Auto => snapshot.active_draft.clone(),
        SelectionMode::Cleared => None,
        SelectionMode::Manual => {
            selected_object.and_then(|selected| find_same_object(snapshot, selected))
        }
    }
}

fn find_same_object(snapshot: &PublicSnapshot, selected: &TrackerItem) -> Option<TrackerItem> {
    snapshot
        .goals
        .iter()
        .chain(snapshot.tasks.iter())
        .chain(snapshot.facts.iter())
        .find(|candidate| candidate.same_object(selected))
        .cloned()
}

fn find_object(snapshot: &PublicSnapshot, kind: &ItemKind, id: &str) -> Option<TrackerItem> {
    let bucket = match kind {
        ItemKind::Goal => &snapshot.goals,
        ItemKind::Task => &snapshot.tasks,
        ItemKind::Fact => &snapshot.facts,
    };

    bucket.iter().find(|item| item.id == id).cloned()
}

fn conversation_target(
    snapshot: &PublicSnapshot,
    actions: &[ToolAction],
    selected_object: Option<&TrackerItem>,
) -> Option<TrackerItem> {
    if let Some(active_draft) = &snapshot.active_draft {
        return Some(active_draft.clone());
    }

    if save_requested(actions) {
        if let Some(kind) = conversation_kind(actions, selected_object) {
            return latest_saved_object(snapshot, &kind);
        }
    }

    selected_object.and_then(|selected| find_same_object(snapshot, selected))
}

fn conversation_kind(
    actions: &[ToolAction],
    selected_object: Option<&TrackerItem>,
) -> Option<ItemKind> {
    selected_object
        .map(|item| item.kind.clone())
        .or_else(|| actions.iter().find_map(|action| action.kind.clone()))
}

fn latest_saved_object(snapshot: &PublicSnapshot, kind: &ItemKind) -> Option<TrackerItem> {
    let bucket = match kind {
        ItemKind::Goal => &snapshot.goals,
        ItemKind::Task => &snapshot.tasks,
        ItemKind::Fact => &snapshot.facts,
    };

    bucket.iter().find(|item| !item.is_drafting()).cloned()
}

fn save_requested(actions: &[ToolAction]) -> bool {
    actions.iter().any(|action| action.tool == "save_draft")
}

fn infer_focus_goal(
    focus_object: Option<&TrackerItem>,
    snapshot: &PublicSnapshot,
) -> Option<String> {
    if let Some(goal) = focus_object.filter(|item| item.kind == ItemKind::Goal) {
        return goal.title.clone();
    }

    if snapshot.goals.len() == 1 {
        return snapshot.goals.first().and_then(|goal| goal.title.clone());
    }

    None
}

fn trim_history(history: Vec<HistoryEntry>) -> Vec<HistoryEntry> {
    let keep_from = history.len().saturating_sub(10);
    history.into_iter().skip(keep_from).collect()
}
