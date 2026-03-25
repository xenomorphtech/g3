use std::{net::SocketAddr, path::PathBuf, sync::Arc};

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use clap::Parser;
use g3_core::{
    AssistantEngine, ChatRequest, ItemKind, ReorderGoalsRequest, SessionInput,
    SpacetimeStoreConfig, TrackerService, WorkspaceStore,
};
use serde::Deserialize;
use serde_json::json;
use tower_http::{cors::CorsLayer, trace::TraceLayer};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(clap::ValueEnum, Clone, Copy, Debug)]
enum StorageBackend {
    File,
    Spacetime,
}

#[derive(Parser, Debug)]
#[command(name = "g3_backend")]
struct Args {
    #[arg(long, default_value = "127.0.0.1")]
    host: String,
    #[arg(long, default_value_t = 8787)]
    port: u16,
    #[arg(long, value_enum, default_value_t = StorageBackend::Spacetime)]
    storage: StorageBackend,
    #[arg(long, default_value = ".local/tracker_state.json")]
    workspace_path: PathBuf,
    #[arg(long, default_value = ".local/gemini.json")]
    gemini_config: PathBuf,
    #[arg(long, default_value = "http://192.168.2.1:3001")]
    spacetime_url: String,
    #[arg(long, default_value = "g3-native-stdb3")]
    spacetime_database: String,
}

#[derive(Clone)]
struct AppState {
    service: TrackerService,
}

#[derive(Debug, Deserialize)]
struct SelectRequest {
    kind: ItemKind,
    id: String,
}

#[derive(Debug, Deserialize, Default)]
struct SessionOnlyRequest {
    #[serde(flatten)]
    session: SessionInput,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer())
        .init();

    let args = Args::parse();
    let store = match args.storage {
        StorageBackend::File => WorkspaceStore::load(&args.workspace_path)?,
        StorageBackend::Spacetime => WorkspaceStore::spacetimedb(SpacetimeStoreConfig::new(
            &args.spacetime_url,
            &args.spacetime_database,
        ))?,
    };
    let service = TrackerService::new(
        store,
        AssistantEngine::from_config_path(&args.gemini_config),
    );

    let state = Arc::new(AppState { service });

    let app = Router::new()
        .route("/api/health", get(health))
        .route("/api/session", get(session))
        .route("/api/chat", post(chat))
        .route("/api/select", post(select))
        .route("/api/clear_selection", post(clear_selection))
        .route("/api/save_draft", post(save_draft))
        .route("/api/clear_draft", post(clear_draft))
        .route("/api/summarize", post(summarize))
        .route("/api/clear_conversation", post(clear_conversation))
        .route("/api/reorder_goals", post(reorder_goals))
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let addr: SocketAddr = format!("{}:{}", args.host, args.port).parse()?;
    tracing::info!("g3 backend listening on http://{addr}");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "status": "ok" }))
}

async fn session(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    Json(json!(state.service.session()))
}

async fn chat(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ChatRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state.service.send_message(request).await?)))
}

async fn select(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SelectRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state
        .service
        .select_object(request.kind, request.id)?)))
}

async fn clear_selection(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    Json(json!(state.service.clear_selection()))
}

async fn save_draft(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SessionOnlyRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state.service.save_draft(request.session)?)))
}

async fn clear_draft(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SessionOnlyRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state.service.clear_draft(request.session)?)))
}

async fn summarize(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SessionOnlyRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(
        state
            .service
            .summarize_conversation(request.session)
            .await?
    )))
}

async fn clear_conversation(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SessionOnlyRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state
        .service
        .clear_conversation(request.session)?)))
}

async fn reorder_goals(
    State(state): State<Arc<AppState>>,
    Json(request): Json<ReorderGoalsRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    Ok(Json(json!(state.service.reorder_goals(request)?)))
}

struct ApiError(g3_core::ServiceError);

impl From<g3_core::ServiceError> for ApiError {
    fn from(value: g3_core::ServiceError) -> Self {
        Self(value)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self.0 {
            g3_core::ServiceError::BadRequest(message) => {
                (StatusCode::UNPROCESSABLE_ENTITY, message)
            }
            g3_core::ServiceError::NotFound(message) => (StatusCode::NOT_FOUND, message),
            g3_core::ServiceError::Internal(error) => {
                tracing::error!("internal backend error: {error:#}");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Internal server error.".to_string(),
                )
            }
        };

        (status, Json(json!({ "error": message }))).into_response()
    }
}
