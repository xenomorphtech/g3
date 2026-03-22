use std::{
    sync::mpsc::{self, Receiver},
    thread,
    time::Duration,
};

use anyhow::Result;
use eframe::egui::{
    self, Align, Button, Color32, Context as EguiContext, Frame, Layout, Margin, RichText,
    ScrollArea, Stroke, TextEdit, Ui, Vec2,
};
use g3_core::{
    ChatRequest, Feedback, FeedbackKind, ItemKind, ReorderGoalsRequest, SessionInput, SessionState,
    TrackerItem,
};
use reqwest::blocking::Client;
use serde::Serialize;
use serde_json::Value;

const BACKEND_URL: &str = "http://127.0.0.1:8787";
const WELCOME_MESSAGE: &str = "Tell me about a goal, task, or fact. The backend will keep a structured draft and save it when it becomes concrete enough.";

pub struct GoalStudioApp {
    backend_url: String,
    composer: String,
    memory_search: String,
    session: Option<SessionState>,
    banner: Option<Feedback>,
    pending_label: Option<String>,
    receiver: Option<Receiver<Result<SessionState, String>>>,
}

impl GoalStudioApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        apply_theme(&cc.egui_ctx);

        let mut app = Self {
            backend_url: BACKEND_URL.to_string(),
            composer: String::new(),
            memory_search: String::new(),
            session: None,
            banner: None,
            pending_label: None,
            receiver: None,
        };
        app.fetch_session();
        app
    }

    fn fetch_session(&mut self) {
        self.spawn_request("Loading session", move |client, base| {
            api_get(&client, &format!("{base}/api/session"))
        });
    }

    fn send_message(&mut self) {
        let message = self.composer.trim().to_string();
        if message.is_empty() || self.pending_label.is_some() {
            return;
        }

        let request = ChatRequest {
            message,
            session: self.session_input(),
        };
        self.composer.clear();
        self.spawn_request("Sending message", move |client, base| {
            api_post(&client, &format!("{base}/api/chat"), &request)
        });
    }

    fn select_object(&mut self, kind: ItemKind, id: String) {
        if self.pending_label.is_some() {
            return;
        }

        #[derive(Serialize)]
        struct SelectRequest {
            kind: ItemKind,
            id: String,
        }

        let request = SelectRequest { kind, id };
        self.spawn_request("Selecting object", move |client, base| {
            api_post(&client, &format!("{base}/api/select"), &request)
        });
    }

    fn clear_selection(&mut self) {
        if self.pending_label.is_some() {
            return;
        }

        self.spawn_request("Clearing selection", move |client, base| {
            api_post_empty(&client, &format!("{base}/api/clear_selection"))
        });
    }

    fn save_draft(&mut self) {
        if self.pending_label.is_some() {
            return;
        }

        let request = SessionOnlyRequest {
            session: self.session_input(),
        };
        self.spawn_request("Saving draft", move |client, base| {
            api_post(&client, &format!("{base}/api/save_draft"), &request)
        });
    }

    fn clear_draft(&mut self) {
        if self.pending_label.is_some() {
            return;
        }

        let request = SessionOnlyRequest {
            session: self.session_input(),
        };
        self.spawn_request("Clearing draft", move |client, base| {
            api_post(&client, &format!("{base}/api/clear_draft"), &request)
        });
    }

    fn summarize(&mut self) {
        if self.pending_label.is_some() {
            return;
        }

        let request = SessionOnlyRequest {
            session: self.session_input(),
        };
        self.spawn_request("Summarizing conversation", move |client, base| {
            api_post(&client, &format!("{base}/api/summarize"), &request)
        });
    }

    fn clear_conversation(&mut self) {
        if self.pending_label.is_some() {
            return;
        }

        let request = SessionOnlyRequest {
            session: self.session_input(),
        };
        self.spawn_request("Clearing conversation", move |client, base| {
            api_post(&client, &format!("{base}/api/clear_conversation"), &request)
        });
    }

    fn move_goal(&mut self, goal_id: &str, direction: isize) {
        let Some(session) = &self.session else {
            return;
        };
        let Some(index) = session
            .snapshot
            .goals
            .iter()
            .position(|goal| goal.id == goal_id)
        else {
            return;
        };

        let next_index = index as isize + direction;
        if next_index < 0 || next_index >= session.snapshot.goals.len() as isize {
            return;
        }

        let mut ids = session
            .snapshot
            .goals
            .iter()
            .map(|goal| goal.id.clone())
            .collect::<Vec<_>>();
        ids.swap(index, next_index as usize);

        let request = ReorderGoalsRequest {
            ids,
            session: self.session_input(),
        };
        self.spawn_request("Reordering goals", move |client, base| {
            api_post(&client, &format!("{base}/api/reorder_goals"), &request)
        });
    }

    fn session_input(&self) -> SessionInput {
        self.session
            .as_ref()
            .map(|session| SessionInput {
                history: session.history.clone(),
                selected_object: session.selected_object.clone(),
                selection_mode: session.selection_mode.clone(),
            })
            .unwrap_or_default()
    }

    fn focused_item(&self) -> Option<&TrackerItem> {
        self.session.as_ref()?.selected_object.as_ref()
    }

    fn active_draft(&self) -> Option<&TrackerItem> {
        self.session.as_ref()?.snapshot.active_draft.as_ref()
    }

    fn focused_is_active_draft(&self) -> bool {
        match (self.focused_item(), self.active_draft()) {
            (Some(focused), Some(active)) => focused.same_object(active),
            _ => false,
        }
    }

    fn spawn_request<F>(&mut self, label: &str, op: F)
    where
        F: FnOnce(Client, String) -> Result<SessionState, String> + Send + 'static,
    {
        let base_url = self.backend_url.trim().trim_end_matches('/').to_string();
        let (sender, receiver) = mpsc::channel();
        self.pending_label = Some(label.to_string());
        self.receiver = Some(receiver);

        thread::spawn(move || {
            let result = Client::builder()
                .timeout(Duration::from_secs(120))
                .build()
                .map_err(|error| error.to_string())
                .and_then(|client| op(client, base_url));
            let _ = sender.send(result);
        });
    }

    fn poll_backend(&mut self, ctx: &EguiContext) {
        if let Some(receiver) = &self.receiver {
            match receiver.try_recv() {
                Ok(result) => {
                    self.receiver = None;
                    self.pending_label = None;
                    match result {
                        Ok(session) => {
                            self.banner = session.feedback.clone();
                            self.session = Some(session);
                        }
                        Err(message) => {
                            self.banner = Some(Feedback {
                                kind: FeedbackKind::Error,
                                message,
                            });
                        }
                    }
                    ctx.request_repaint();
                }
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.receiver = None;
                    self.pending_label = None;
                    self.banner = Some(Feedback {
                        kind: FeedbackKind::Error,
                        message: "The backend request channel closed unexpectedly.".to_string(),
                    });
                }
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
    }
}

impl eframe::App for GoalStudioApp {
    fn update(&mut self, ctx: &EguiContext, _frame: &mut eframe::Frame) {
        self.poll_backend(ctx);

        egui::TopBottomPanel::top("topbar")
            .resizable(false)
            .show(ctx, |ui| self.render_topbar(ui));

        let wide = ctx.available_rect().width() >= 1180.0;
        if wide {
            egui::SidePanel::left("collections")
                .min_width(320.0)
                .resizable(true)
                .show(ctx, |ui| self.render_lists(ui));

            egui::SidePanel::right("details")
                .min_width(360.0)
                .resizable(true)
                .show(ctx, |ui| self.render_details(ui));

            egui::CentralPanel::default().show(ctx, |ui| self.render_chat(ui));
        } else {
            egui::TopBottomPanel::top("collections_compact")
                .default_height(210.0)
                .resizable(true)
                .show(ctx, |ui| self.render_lists(ui));

            egui::TopBottomPanel::bottom("details_compact")
                .default_height(220.0)
                .resizable(true)
                .show(ctx, |ui| self.render_details(ui));

            egui::CentralPanel::default().show(ctx, |ui| self.render_chat(ui));
        }
    }
}

impl GoalStudioApp {
    fn render_topbar(&mut self, ui: &mut Ui) {
        Frame::new()
            .fill(Color32::from_rgb(8, 8, 10))
            .inner_margin(Margin::symmetric(18, 10))
            .show(ui, |ui| {
                ui.horizontal(|ui| {
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let refresh = ui.add_enabled(
                            self.pending_label.is_none(),
                            Button::new("Reconnect").fill(Color32::from_rgb(39, 190, 160)),
                        );
                        if refresh.clicked() {
                            self.fetch_session();
                        }

                        ui.add_sized(
                            [280.0, 30.0],
                            TextEdit::singleline(&mut self.backend_url)
                                .hint_text("http://127.0.0.1:8787"),
                        );
                        ui.label(RichText::new("Backend").color(Color32::from_rgb(220, 220, 224)));
                    });
                });

                if let Some(pending) = &self.pending_label {
                    ui.add_space(10.0);
                    ui.label(RichText::new(pending).color(Color32::from_rgb(250, 204, 21)));
                }

                if let Some(banner) = &self.banner {
                    ui.add_space(10.0);
                    let (fill, text) = match banner.kind {
                        FeedbackKind::Info => (
                            Color32::from_rgb(12, 51, 43),
                            Color32::from_rgb(190, 242, 220),
                        ),
                        FeedbackKind::Error => (
                            Color32::from_rgb(68, 18, 24),
                            Color32::from_rgb(255, 214, 214),
                        ),
                    };

                    Frame::new()
                        .fill(fill)
                        .corner_radius(12.0)
                        .inner_margin(Margin::same(10))
                        .show(ui, |ui| {
                            ui.label(RichText::new(&banner.message).color(text));
                        });
                }
            });
    }

    fn render_lists(&mut self, ui: &mut Ui) {
        let Some(session) = self.session.clone() else {
            centered_empty(ui, "Connecting to the backend...");
            return;
        };

        ScrollArea::vertical().show(ui, |ui| {
            ui.add_space(6.0);
            ui.heading("Tracker context");
            ui.label(
                RichText::new("Choose a goal, task, or fact to focus the conversation.")
                    .color(Color32::from_rgb(154, 154, 162)),
            );
            ui.add_space(12.0);

            count_cards(
                ui,
                session.snapshot.goals.len(),
                session.snapshot.tasks.len(),
                session.snapshot.facts.len(),
            );
            ui.add_space(12.0);

            self.render_item_section(ui, "Goals", &session.snapshot.goals, true);
            self.render_item_section(ui, "Tasks", &session.snapshot.tasks, false);
            self.render_item_section(ui, "Facts", &session.snapshot.facts, false);
        });
    }

    fn render_item_section(
        &mut self,
        ui: &mut Ui,
        title: &str,
        items: &[TrackerItem],
        allow_reorder: bool,
    ) {
        ui.add_space(10.0);
        ui.horizontal(|ui| {
            ui.heading(title);
            ui.label(
                RichText::new(items.len().to_string()).color(Color32::from_rgb(156, 156, 164)),
            );
        });

        if items.is_empty() {
            pill(
                ui,
                "No items yet",
                Color32::from_rgb(28, 28, 31),
                Color32::from_rgb(222, 222, 228),
            );
            return;
        }

        for item in items {
            let selected = self
                .focused_item()
                .is_some_and(|focused| focused.same_object(item));

            let fill = if selected {
                Color32::from_rgb(17, 74, 64)
            } else {
                Color32::from_rgb(18, 18, 20)
            };

            Frame::new()
                .fill(fill)
                .stroke(Stroke::new(
                    1.0,
                    if selected {
                        Color32::from_rgb(55, 225, 191)
                    } else {
                        Color32::from_rgb(52, 52, 56)
                    },
                ))
                .corner_radius(18.0)
                .inner_margin(Margin::same(12))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.vertical(|ui| {
                            if ui
                                .add(
                                    Button::new(
                                        RichText::new(item.title_or("Untitled"))
                                            .color(Color32::from_rgb(245, 245, 248))
                                            .strong(),
                                    )
                                    .fill(Color32::TRANSPARENT)
                                    .stroke(Stroke::NONE),
                                )
                                .clicked()
                            {
                                self.select_object(item.kind.clone(), item.id.clone());
                            }

                            if let Some(lead) = item.lead_text() {
                                ui.label(
                                    RichText::new(lead)
                                        .size(13.0)
                                        .color(Color32::from_rgb(186, 186, 194)),
                                );
                            }

                            ui.horizontal_wrapped(|ui| {
                                for fact in quick_tags(item) {
                                    pill(
                                        ui,
                                        &fact,
                                        Color32::from_rgb(26, 26, 29),
                                        Color32::from_rgb(212, 212, 218),
                                    );
                                }
                            });
                        });

                        ui.with_layout(Layout::right_to_left(Align::Min), |ui| {
                            if allow_reorder {
                                if ui
                                    .add_enabled(
                                        self.pending_label.is_none(),
                                        Button::new("↓").fill(Color32::from_rgb(26, 26, 29)),
                                    )
                                    .clicked()
                                {
                                    self.move_goal(&item.id, 1);
                                }
                                if ui
                                    .add_enabled(
                                        self.pending_label.is_none(),
                                        Button::new("↑").fill(Color32::from_rgb(26, 26, 29)),
                                    )
                                    .clicked()
                                {
                                    self.move_goal(&item.id, -1);
                                }
                            }

                            pill(
                                ui,
                                item.status.as_deref().unwrap_or("unknown"),
                                Color32::from_rgb(30, 30, 34),
                                Color32::from_rgb(226, 226, 232),
                            );
                        });
                    });
                });
            ui.add_space(8.0);
        }
    }

    fn render_chat(&mut self, ui: &mut Ui) {
        let session = self.session.clone();

        Frame::new()
            .fill(Color32::from_rgb(10, 18, 30))
            .inner_margin(Margin::same(18))
            .show(ui, |ui| {
                ui.heading("Studio chat");
                ui.label(
                    RichText::new("Shape work in natural language. The backend turns each turn into structured state.")
                        .color(Color32::from_rgb(144, 158, 179)),
                );
                ui.add_space(14.0);

                let available_height = ui.available_height();
                let composer_height = if available_height < 360.0 { 92.0 } else { 132.0 };
                let actions_height = 42.0;
                let composer_panel_padding = 54.0;
                let messages_height =
                    (available_height - composer_height - actions_height - composer_panel_padding)
                        .max(88.0);

                ScrollArea::vertical()
                    .auto_shrink([false, false])
                    .stick_to_bottom(true)
                    .max_height(messages_height)
                    .show(ui, |ui| {
                        if let Some(session) = &session {
                            if session.history.is_empty() {
                                render_message(ui, "assistant", WELCOME_MESSAGE, false);
                            } else {
                                for entry in &session.history {
                                    render_message(ui, &entry.role, &entry.content, entry.follow_up);
                                }
                            }
                        } else {
                            render_message(ui, "assistant", "Waiting for session state...", false);
                        }
                    });

                ui.add_space(12.0);
                Frame::new()
                    .fill(Color32::from_rgb(18, 27, 41))
                    .stroke(Stroke::new(1.0, Color32::from_rgb(46, 61, 82)))
                    .corner_radius(18.0)
                    .inner_margin(Margin::same(12))
                    .show(ui, |ui| {
                        ui.label(
                            RichText::new("Compose")
                                .size(12.0)
                                .color(Color32::from_rgb(134, 149, 171)),
                        );
                        ui.add_space(6.0);

                        let input = ui.add_sized(
                            [ui.available_width(), composer_height],
                            TextEdit::multiline(&mut self.composer)
                                .hint_text("Examples: \"I want to launch my portfolio site by June.\" or \"Create a task to send the planning deck by 2026-03-20.\""),
                        );

                        let ctrl_enter = input.has_focus()
                            && ui.input(|state| {
                                state.key_pressed(egui::Key::Enter) && state.modifiers.ctrl
                            });

                        ui.add_space(10.0);
                        ui.horizontal(|ui| {
                            ui.label(
                                RichText::new("Ctrl+Enter sends")
                                    .color(Color32::from_rgb(128, 142, 165)),
                            );
                            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                if ui
                                    .add_enabled(
                                        self.pending_label.is_none()
                                            && !self.composer.trim().is_empty(),
                                        Button::new("Send")
                                            .fill(Color32::from_rgb(39, 190, 160)),
                                    )
                                    .clicked()
                                    || ctrl_enter
                                {
                                    self.send_message();
                                }
                            });
                        });
                    });
            });
    }

    fn render_details(&mut self, ui: &mut Ui) {
        let Some(session) = self.session.clone() else {
            centered_empty(ui, "No session data yet.");
            return;
        };

        ScrollArea::vertical().show(ui, |ui| {
            ui.heading("Object memory");
            ui.label(
                RichText::new("Readable context for the focused object, plus the actions that affect it.")
                    .color(Color32::from_rgb(126, 141, 163)),
            );
            ui.add_space(12.0);

            ui.horizontal(|ui| {
                ui.add_sized(
                    [ui.available_width() - 72.0, 34.0],
                    TextEdit::singleline(&mut self.memory_search)
                        .hint_text("Search saved memory, notes, and conversations..."),
                );
                if ui
                    .add_enabled(
                        !self.memory_search.trim().is_empty(),
                        Button::new("Clear").fill(Color32::from_rgb(37, 48, 66)),
                    )
                    .clicked()
                {
                    self.memory_search.clear();
                }
            });

            if !self.memory_search.trim().is_empty() {
                ui.add_space(12.0);
                self.render_memory_search_results(ui, &session);
                ui.add_space(16.0);
            }

            if let Some(item) = &session.selected_object {
                pill(
                    ui,
                    &format!("{} • {}", item.kind.as_str(), item.status.as_deref().unwrap_or("unknown")),
                    Color32::from_rgb(20, 85, 74),
                    Color32::from_rgb(215, 247, 240),
                );

                ui.add_space(10.0);
                ui.heading(item.title_or("Untitled"));
                if let Some(lead) = item.lead_text() {
                    ui.label(RichText::new(lead).color(Color32::from_rgb(196, 206, 222)));
                }
                if let Some(summary) = &item.origin_summary {
                    ui.add_space(8.0);
                    Frame::new()
                        .fill(Color32::from_rgb(69, 46, 15))
                        .corner_radius(14.0)
                        .inner_margin(Margin::same(10))
                        .show(ui, |ui| {
                            ui.label(RichText::new(summary).color(Color32::from_rgb(255, 231, 187)));
                        });
                }

                ui.add_space(10.0);
                ui.horizontal_wrapped(|ui| {
                    for tag in quick_tags(item) {
                        pill(ui, &tag, Color32::from_rgb(36, 49, 69), Color32::from_rgb(193, 206, 224));
                    }
                });

                ui.add_space(14.0);
                ui.horizontal_wrapped(|ui| {
                    if ui.button("Clear focus").clicked() {
                        self.clear_selection();
                    }
                    if ui
                        .add_enabled(self.pending_label.is_none(), Button::new("Summarize"))
                        .clicked()
                    {
                        self.summarize();
                    }
                    if ui
                        .add_enabled(self.pending_label.is_none(), Button::new("Clear convo"))
                        .clicked()
                    {
                        self.clear_conversation();
                    }
                    if self.focused_is_active_draft() {
                        if ui
                            .add_enabled(self.pending_label.is_none(), Button::new("Save"))
                            .clicked()
                        {
                            self.save_draft();
                        }
                        if ui
                            .add_enabled(self.pending_label.is_none(), Button::new("Clear draft"))
                            .clicked()
                        {
                            self.clear_draft();
                        }
                    }
                });

                ui.add_space(14.0);
                render_detail_rows(ui, item);
                ui.add_space(12.0);

                let history_count = item
                    .origin_conversation
                    .as_ref()
                    .map(|history| history.len())
                    .unwrap_or(0);
                pill(
                    ui,
                    &format!("{history_count} conversation entries"),
                    Color32::from_rgb(34, 42, 58),
                    Color32::from_rgb(184, 193, 208),
                );
            } else {
                centered_empty(
                    ui,
                    "Select a goal, task, or fact to inspect its details and manage the current draft.",
                );
            }
        });
    }

    fn render_memory_search_results(&mut self, ui: &mut Ui, session: &SessionState) {
        let results = memory_search_results(session, &self.memory_search);

        ui.horizontal(|ui| {
            ui.heading("Matches");
            ui.label(
                RichText::new(results.len().to_string()).color(Color32::from_rgb(141, 152, 170)),
            );
        });

        if results.is_empty() {
            Frame::new()
                .fill(Color32::from_rgb(24, 31, 44))
                .corner_radius(16.0)
                .inner_margin(Margin::same(12))
                .show(ui, |ui| {
                    ui.label(
                        RichText::new("No memory matched that query.")
                            .color(Color32::from_rgb(182, 191, 206)),
                    );
                });
            return;
        }

        for result in results {
            let selected = self
                .focused_item()
                .is_some_and(|focused| focused.same_object(&result.item));

            Frame::new()
                .fill(if selected {
                    Color32::from_rgb(17, 74, 64)
                } else {
                    Color32::from_rgb(24, 31, 44)
                })
                .stroke(Stroke::new(
                    1.0,
                    if selected {
                        Color32::from_rgb(55, 225, 191)
                    } else {
                        Color32::from_rgb(50, 63, 82)
                    },
                ))
                .corner_radius(16.0)
                .inner_margin(Margin::same(12))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.vertical(|ui| {
                            ui.horizontal_wrapped(|ui| {
                                pill(
                                    ui,
                                    result.item.kind.as_str(),
                                    Color32::from_rgb(36, 49, 69),
                                    Color32::from_rgb(193, 206, 224),
                                );
                                pill(
                                    ui,
                                    &result.field,
                                    Color32::from_rgb(54, 46, 16),
                                    Color32::from_rgb(249, 220, 146),
                                );
                            });
                            ui.add_space(6.0);
                            ui.label(
                                RichText::new(result.item.title_or("Untitled"))
                                    .strong()
                                    .color(Color32::from_rgb(240, 245, 250)),
                            );
                            ui.label(
                                RichText::new(result.snippet)
                                    .size(13.0)
                                    .color(Color32::from_rgb(182, 193, 209)),
                            );
                        });

                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui
                                .add(
                                    Button::new("Open")
                                        .fill(Color32::from_rgb(39, 190, 160))
                                        .min_size(Vec2::new(64.0, 30.0)),
                                )
                                .clicked()
                            {
                                self.select_object(
                                    result.item.kind.clone(),
                                    result.item.id.clone(),
                                );
                            }
                        });
                    });
                });
            ui.add_space(8.0);
        }
    }
}

#[derive(Serialize)]
struct SessionOnlyRequest {
    #[serde(flatten)]
    session: SessionInput,
}

fn api_get(client: &Client, url: &str) -> Result<SessionState, String> {
    let response = client.get(url).send().map_err(|error| error.to_string())?;
    parse_session_response(response)
}

fn api_post<T: Serialize>(client: &Client, url: &str, body: &T) -> Result<SessionState, String> {
    let response = client
        .post(url)
        .json(body)
        .send()
        .map_err(|error| error.to_string())?;
    parse_session_response(response)
}

fn api_post_empty(client: &Client, url: &str) -> Result<SessionState, String> {
    let response = client.post(url).send().map_err(|error| error.to_string())?;
    parse_session_response(response)
}

fn parse_session_response(response: reqwest::blocking::Response) -> Result<SessionState, String> {
    let status = response.status();
    let body = response.text().map_err(|error| error.to_string())?;
    if status.is_success() {
        serde_json::from_str(&body).map_err(|error| error.to_string())
    } else {
        let message = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|value| {
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
            })
            .unwrap_or_else(|| format!("Backend request failed with status {status}."));
        Err(message)
    }
}

fn render_message(ui: &mut Ui, role: &str, content: &str, follow_up: bool) {
    let user = role == "user";
    ui.with_layout(
        if user {
            Layout::right_to_left(Align::Min)
        } else {
            Layout::left_to_right(Align::Min)
        },
        |ui| {
            Frame::new()
                .fill(if user {
                    Color32::from_rgb(39, 190, 160)
                } else {
                    Color32::from_rgb(23, 33, 49)
                })
                .corner_radius(22.0)
                .inner_margin(Margin::same(14))
                .show(ui, |ui| {
                    ui.vertical(|ui| {
                        ui.horizontal(|ui| {
                            ui.label(
                                RichText::new(if user { "You" } else { "Studio" })
                                    .strong()
                                    .color(if user {
                                        Color32::from_rgb(8, 19, 18)
                                    } else {
                                        Color32::from_rgb(185, 202, 222)
                                    }),
                            );
                            if follow_up {
                                pill(
                                    ui,
                                    "Needs details",
                                    Color32::from_rgb(99, 67, 19),
                                    Color32::from_rgb(255, 234, 184),
                                );
                            }
                        });
                        ui.label(RichText::new(content).color(if user {
                            Color32::from_rgb(4, 14, 13)
                        } else {
                            Color32::from_rgb(235, 241, 248)
                        }));
                    });
                });
        },
    );
    ui.add_space(8.0);
}

fn render_detail_rows(ui: &mut Ui, item: &TrackerItem) {
    for (label, value) in [
        ("Summary", item.summary.clone()),
        ("Details", item.details.clone()),
        ("Success criteria", item.success_criteria.clone()),
        ("Target date", item.target_date.clone()),
        ("Due date", item.due_date.clone()),
        ("Priority", item.priority.clone()),
        ("Parent goal", item.parent_goal_title.clone()),
        ("Project", item.project_title.clone()),
    ] {
        let Some(value) = value.filter(|value| !value.trim().is_empty()) else {
            continue;
        };

        Frame::new()
            .fill(Color32::from_rgb(24, 31, 44))
            .corner_radius(16.0)
            .inner_margin(Margin::same(12))
            .show(ui, |ui| {
                ui.label(
                    RichText::new(label)
                        .size(12.0)
                        .color(Color32::from_rgb(128, 141, 162)),
                );
                ui.label(RichText::new(value).color(Color32::from_rgb(235, 240, 247)));
            });
        ui.add_space(8.0);
    }
}

fn quick_tags(item: &TrackerItem) -> Vec<String> {
    [
        item.target_date
            .as_ref()
            .map(|value| format!("Target {value}")),
        item.due_date.as_ref().map(|value| format!("Due {value}")),
        item.priority.clone(),
        item.parent_goal_title.clone(),
        item.project_title.clone(),
    ]
    .into_iter()
    .flatten()
    .collect()
}

#[derive(Clone)]
struct MemorySearchResult {
    item: TrackerItem,
    field: String,
    snippet: String,
    score: usize,
}

fn memory_search_results(session: &SessionState, query: &str) -> Vec<MemorySearchResult> {
    let tokens = query
        .to_lowercase()
        .split_whitespace()
        .map(str::trim)
        .filter(|token| !token.is_empty())
        .map(ToString::to_string)
        .collect::<Vec<_>>();

    if tokens.is_empty() {
        return Vec::new();
    }

    let selected = session.selected_object.as_ref();
    let mut results = session
        .snapshot
        .goals
        .iter()
        .chain(session.snapshot.tasks.iter())
        .chain(session.snapshot.facts.iter())
        .filter_map(|item| score_memory_item(item, &tokens, selected))
        .collect::<Vec<_>>();

    results.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.item.kind.as_str().cmp(right.item.kind.as_str()))
            .then_with(|| left.item.title.cmp(&right.item.title))
    });
    results.truncate(8);
    results
}

fn score_memory_item(
    item: &TrackerItem,
    tokens: &[String],
    selected: Option<&TrackerItem>,
) -> Option<MemorySearchResult> {
    let mut best_score = 0;
    let mut best_field = None::<String>;
    let mut best_snippet = None::<String>;

    for (field, value) in searchable_item_fields(item) {
        let lower = value.to_lowercase();
        let matched = tokens
            .iter()
            .filter(|token| lower.contains(token.as_str()))
            .count();
        if matched == 0 {
            continue;
        }

        let title_bonus = usize::from(field == "title") * 3;
        let selected_bonus =
            usize::from(selected.is_some_and(|focused| focused.same_object(item))) * 2;
        let score = matched + title_bonus + selected_bonus;

        if score > best_score {
            best_score = score;
            best_field = Some(field.to_string());
            best_snippet = Some(truncate(&value, 160));
        }
    }

    Some(MemorySearchResult {
        item: item.clone(),
        field: best_field?,
        snippet: best_snippet?,
        score: best_score,
    })
}

fn searchable_item_fields(item: &TrackerItem) -> Vec<(&'static str, String)> {
    let mut fields = Vec::new();

    for (name, value) in [
        ("title", item.title.clone()),
        ("summary", item.summary.clone()),
        ("details", item.details.clone()),
        ("success criteria", item.success_criteria.clone()),
        ("target date", item.target_date.clone()),
        ("due date", item.due_date.clone()),
        ("priority", item.priority.clone()),
        ("parent goal", item.parent_goal_title.clone()),
        ("project", item.project_title.clone()),
        ("conversation summary", item.origin_summary.clone()),
    ] {
        if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
            fields.push((name, value));
        }
    }

    if let Some(conversation) = &item.origin_conversation {
        for entry in conversation {
            if !entry.content.trim().is_empty() {
                fields.push(("conversation", entry.content.clone()));
            }
        }
    }

    fields
}

fn count_cards(ui: &mut Ui, goals: usize, tasks: usize, facts: usize) {
    ui.columns(3, |columns| {
        stat_card(&mut columns[0], "Goals", goals);
        stat_card(&mut columns[1], "Tasks", tasks);
        stat_card(&mut columns[2], "Facts", facts);
    });
}

fn stat_card(ui: &mut Ui, label: &str, value: usize) {
    Frame::new()
        .fill(Color32::from_rgb(24, 31, 44))
        .corner_radius(18.0)
        .inner_margin(Margin::same(12))
        .show(ui, |ui| {
            ui.label(RichText::new(label).color(Color32::from_rgb(130, 145, 165)));
            ui.label(
                RichText::new(value.to_string())
                    .size(28.0)
                    .strong()
                    .color(Color32::from_rgb(239, 243, 248)),
            );
        });
}

fn pill(ui: &mut Ui, text: &str, fill: Color32, color: Color32) {
    Frame::new()
        .fill(fill)
        .corner_radius(999.0)
        .inner_margin(Margin::symmetric(10, 6))
        .show(ui, |ui| {
            ui.label(RichText::new(text).size(11.0).color(color));
        });
}

fn centered_empty(ui: &mut Ui, text: &str) {
    ui.allocate_ui_with_layout(
        ui.available_size(),
        Layout::centered_and_justified(egui::Direction::TopDown),
        |ui| {
            ui.label(RichText::new(text).color(Color32::from_rgb(144, 158, 179)));
        },
    );
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

fn apply_theme(ctx: &EguiContext) {
    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = Vec2::new(10.0, 10.0);
    style.spacing.button_padding = Vec2::new(14.0, 10.0);
    style.visuals.window_fill = Color32::from_rgb(12, 17, 27);
    style.visuals.panel_fill = Color32::from_rgb(12, 17, 27);
    style.visuals.widgets.inactive.corner_radius = 16.0.into();
    style.visuals.widgets.active.corner_radius = 16.0.into();
    style.visuals.widgets.hovered.corner_radius = 16.0.into();
    style.visuals.widgets.inactive.bg_fill = Color32::from_rgb(28, 37, 52);
    style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(41, 53, 73);
    style.visuals.widgets.active.bg_fill = Color32::from_rgb(39, 190, 160);
    style.visuals.selection.bg_fill = Color32::from_rgb(39, 190, 160);
    style.visuals.override_text_color = Some(Color32::from_rgb(232, 238, 247));
    ctx.set_style(style);
    ctx.set_visuals(egui::Visuals::dark());
}
