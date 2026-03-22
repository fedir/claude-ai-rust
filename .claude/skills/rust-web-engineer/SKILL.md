# Rust Web Engineer Skill

Full implementation guide for Rust web services with axum, sqlx, authentication, testing, and cloud deployment.

## When to Use
- Building axum REST services from scratch
- Implementing auth, database, or cloud features
- Need reference implementations for common patterns

## Reference Files

| Reference | Contents |
|-----------|---------|
| `references/web.md` | axum router, handlers, extractors, error responses, validation, CORS |
| `references/data.md` | sqlx entities, queries, transactions, migrations, pagination |
| `references/auth.md` | JWT middleware, argon2 password hashing, OAuth2, RBAC |
| `references/testing.md` | axum-test unit tests, integration tests, wiremock, testcontainers |
| `references/cloud.md` | Dockerfile, GitHub Actions, health checks, Kubernetes manifests |

---

## Minimal Working Structure

```rust
// src/main.rs
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().json().init();

    let database_url = std::env::var("DATABASE_URL")?;
    let pool = sqlx::PgPool::connect(&database_url).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;

    let state = AppState { pool };
    let app = Router::new()
        .route("/health", get(health))
        .nest("/api/v1", api_router())
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}
```

---

## Implementation Workflow

### 1. Domain Model
Define types first — make invalid states unrepresentable:
```rust
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub name: String,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, sqlx::Type, serde::Serialize, serde::Deserialize)]
#[sqlx(type_name = "user_status", rename_all = "lowercase")]
pub enum UserStatus { Active, Inactive, Suspended }
```

### 2. Error Types

> **Canonical `AppError`** is in `rust-architect/references/rust-setup.md`.
> Variants: `NotFound`, `Validation`, `Unauthorized`, `TokenExpired`, `Forbidden`,
> `Conflict`, `Database`, `Internal`. Each maps to correct HTTP status code.

### 3. Data Layer (sqlx queries)
```rust
pub async fn find_user(pool: &PgPool, id: Uuid) -> Result<Option<User>, sqlx::Error> {
    sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_optional(pool)
        .await
}
```

### 4. Service Layer (business logic)
```rust
pub async fn create_user(
    pool: &PgPool,
    req: CreateUserRequest,
) -> Result<User, AppError> {
    req.validate()?;
    let hash = hash_password(&req.password)?;
    db::users::create(pool, &req.email, &req.name, &hash).await
        .map_err(AppError::from)
}
```

### 5. Handlers (thin, delegate to service)
```rust
pub async fn create_user_handler(
    State(state): State<AppState>,
    Json(req): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    let user = services::user::create_user(&state.pool, req).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(user))))
}
```

### 6. Tests
```rust
#[tokio::test]
async fn test_create_user() {
    let app = TestApp::new().await;
    let response = app.post("/api/v1/users")
        .json(&json!({ "email": "alice@example.com", "name": "Alice", "password": "secret123" }))
        .await;
    assert_eq!(response.status_code(), 201);
}
```

---

## MUST DO

- `State<AppState>` — axum wraps in Arc internally; do NOT double-wrap
- Validate request DTOs at handler boundary with `validator` (or `garde`)
- Map `sqlx::Error` to domain errors, never expose raw DB errors
- All async database functions return `Result<T, sqlx::Error>` or `Result<T, AppError>`
- Graceful shutdown with `with_graceful_shutdown`
- Health and readiness endpoints for Kubernetes

## MUST NOT DO

- No `unwrap()` / `expect()` in handlers or services
- No business logic in handlers — only orchestration
- No `std::sync::Mutex` in `AppState` — use `tokio::sync::RwLock`
- Never return internal error messages to API clients
- No database queries directly in handlers — use db module
