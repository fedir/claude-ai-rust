# Rust Web Patterns Skill

axum patterns and best practices: handlers, extractors, shared state, middleware, error responses, and project structure.

## When to Use
- Building axum web services
- Designing REST API handlers and routes
- Adding middleware, authentication, or validation

---

## Project Structure

```
src/
├── main.rs              # Entry point: init tracing, pool, router, bind
├── config.rs            # Config from env vars (config crate or envy)
├── error.rs             # AppError enum + IntoResponse impl
├── state.rs             # AppState struct
├── router.rs            # Router composition
├── models/
│   ├── mod.rs
│   └── user.rs          # DB row structs (#[derive(sqlx::FromRow)])
├── dto/
│   ├── mod.rs
│   └── user.rs          # Request/Response types (#[derive(serde)])
├── handlers/
│   ├── mod.rs
│   └── users.rs         # axum handler functions (thin!)
├── services/
│   ├── mod.rs
│   └── user_service.rs  # Business logic
└── db/
    ├── mod.rs
    └── users.rs         # sqlx queries
```

---

## AppState

```rust
use std::sync::Arc;
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
}
```

---

## Router Composition

```rust
use axum::{Router, routing::{get, post, put, delete}};

pub fn create_router(state: AppState) -> Router {
    Router::new()
        .nest("/api/v1", api_routes())
        .layer(
            tower::ServiceBuilder::new()
                .layer(TraceLayer::new_for_http())
                .layer(CorsLayer::permissive())
                .layer(TimeoutLayer::new(Duration::from_secs(30)))
                .layer(CompressionLayer::new()),
        )
        .with_state(state)
}

fn api_routes() -> Router<AppState> {
    Router::new()
        .nest("/users", user_routes())
        .nest("/orders", order_routes())
}

fn user_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(handlers::users::list).post(handlers::users::create))
        .route("/:id", get(handlers::users::get_by_id)
            .put(handlers::users::update)
            .delete(handlers::users::delete))
}
```

---

## Handler Pattern (thin handlers)

```rust
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use uuid::Uuid;

use crate::{dto::user::{CreateUserRequest, UserResponse, ListUsersQuery}, error::AppError, state::AppState};

// List with pagination
pub async fn list(
    State(state): State<AppState>,
    Query(params): Query<ListUsersQuery>,
) -> Result<Json<Vec<UserResponse>>, AppError> {
    let users = services::user::list(&state.pool, params.page, params.per_page).await?;
    Ok(Json(users.into_iter().map(UserResponse::from).collect()))
}

// Get by ID
pub async fn get_by_id(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<UserResponse>, AppError> {
    let user = services::user::find_by_id(&state.pool, id)
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(UserResponse::from(user)))
}

// Create
pub async fn create(
    State(state): State<AppState>,
    Json(req): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    req.validate()?;
    let user = services::user::create(&state.pool, req).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(user))))
}
```

---

## DTO Types

```rust
use serde::{Deserialize, Serialize};
use validator::Validate;

#[derive(Debug, Deserialize, Validate)]
pub struct CreateUserRequest {
    #[validate(length(min = 1, max = 100))]
    pub name: String,
    #[validate(email)]
    pub email: String,
    #[validate(length(min = 8))]
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct UserResponse {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

impl From<User> for UserResponse {
    fn from(u: User) -> Self {
        Self { id: u.id, name: u.name, email: u.email, created_at: u.created_at }
    }
}

#[derive(Debug, Deserialize)]
pub struct ListUsersQuery {
    #[serde(default = "default_page")]
    pub page: i64,
    #[serde(default = "default_per_page")]
    pub per_page: i64,
}

fn default_page() -> i64 { 1 }
fn default_per_page() -> i64 { 20 }
```

---

## Error Handling

```rust
use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found")]
    NotFound,
    #[error("validation error: {0}")]
    Validation(#[from] validator::ValidationErrors),
    #[error("unauthorized")]
    Unauthorized,
    #[error("forbidden")]
    Forbidden,
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("database error")]
    Database(#[from] sqlx::Error),
    #[error("internal error")]
    Internal(#[from] anyhow::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND", self.to_string()),
            AppError::Validation(e) => (StatusCode::UNPROCESSABLE_ENTITY, "VALIDATION_ERROR", e.to_string()),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "UNAUTHORIZED", self.to_string()),
            AppError::Forbidden => (StatusCode::FORBIDDEN, "FORBIDDEN", self.to_string()),
            AppError::Conflict(msg) => (StatusCode::CONFLICT, "CONFLICT", msg.clone()),
            AppError::Database(sqlx::Error::RowNotFound) => (StatusCode::NOT_FOUND, "NOT_FOUND", "not found".into()),
            AppError::Database(e) if is_unique_violation(e) => (StatusCode::CONFLICT, "CONFLICT", "already exists".into()),
            _ => {
                tracing::error!(error = %self, "Internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", "internal server error".into())
            }
        };

        (status, Json(json!({ "error": code, "message": message }))).into_response()
    }
}
```

---

## Custom Extractor (JWT Auth)

```rust
use axum::{extract::FromRequestParts, http::request::Parts};
use axum_extra::TypedHeader;
use headers::{Authorization, authorization::Bearer};

pub struct AuthUser {
    pub user_id: Uuid,
    pub roles: Vec<String>,
}

#[async_trait::async_trait]
impl<S> FromRequestParts<S> for AuthUser
where
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let TypedHeader(Authorization(bearer)) =
            TypedHeader::<Authorization<Bearer>>::from_request_parts(parts, _state)
                .await
                .map_err(|_| AppError::Unauthorized)?;

        let claims = verify_jwt(bearer.token()).map_err(|_| AppError::Unauthorized)?;
        Ok(AuthUser { user_id: claims.sub, roles: claims.roles })
    }
}

// Usage in handler:
pub async fn admin_only(
    AuthUser { user_id, roles }: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, AppError> {
    if !roles.contains(&"admin".to_string()) {
        return Err(AppError::Forbidden);
    }
    // ...
}
```

---

## Graceful Shutdown

```rust
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    init_tracing();
    let config = Config::from_env()?;
    let pool = create_pool(&config.database_url).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;

    let state = AppState { pool, config: Arc::new(config) };
    let app = create_router(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 8080));
    let listener = tokio::net::TcpListener::bind(addr).await?;

    info!(%addr, "Server listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async { tokio::signal::ctrl_c().await.expect("failed to install Ctrl+C handler") };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }

    info!("Shutdown signal received, draining connections");
}
```

---

## Health Endpoints

```rust
use serde_json::json;

pub async fn health() -> impl IntoResponse {
    Json(json!({ "status": "ok" }))
}

pub async fn ready(State(state): State<AppState>) -> impl IntoResponse {
    match sqlx::query("SELECT 1").execute(&state.pool).await {
        Ok(_) => Json(json!({ "status": "ready" })).into_response(),
        Err(_) => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({ "status": "not ready" }))).into_response(),
    }
}
```

---

## Best Practices

| Rule | Rationale |
|------|-----------|
| Thin handlers | Testable business logic in services |
| `Arc<AppState>` | Cheaply cloned across requests |
| Never return internal errors | Security: no stack traces to clients |
| Validate at extractor level | Early rejection before business logic |
| Use `?` throughout | Clean propagation via `IntoResponse` |
| Log at service layer | Not in handlers (too noisy) |
| Typed path params `Path<Uuid>` | Auto-validated, no manual parsing |
| `(StatusCode, Json<T>)` for 201 | Explicit status for creation |
