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
├── config.rs            # Config from env vars (config crate)
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

axum wraps state in `Arc` internally when you call `.with_state()`.
Do NOT double-wrap with `Arc<AppState>`. Just derive `Clone`.
`PgPool` is already `Arc`-based internally, so cloning is cheap.

```rust
use sqlx::PgPool;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: AppConfig,
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

> **Canonical `AppError` definition** is in `rust-architect/references/rust-setup.md`.
> Key mapping: `NotFound` → 404, `Validation` → 422, `Unauthorized` → 401,
> `Forbidden` → 403, `Conflict` → 409, `Database` → 404/409/500, `Internal` → 500.
> Never expose internal error details to clients.

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

// Native async fn in traits — no async-trait crate needed (Rust 1.75+)
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

> **Canonical `main.rs` + `shutdown_signal()`** is in `rust-architect/references/rust-setup.md`.
> Key pattern: `axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await?;`
> Handles both `SIGINT` (Ctrl+C) and `SIGTERM` (container orchestrator).

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
| `State<AppState>` | axum auto-wraps in Arc; don't double-wrap |
| Never return internal errors | Security: no stack traces to clients |
| Validate at extractor level | Early rejection before business logic |
| Use `?` throughout | Clean propagation via `IntoResponse` |
| Log at service layer | Not in handlers (too noisy) |
| Typed path params `Path<Uuid>` | Auto-validated, no manual parsing |
| `(StatusCode, Json<T>)` for 201 | Explicit status for creation |
