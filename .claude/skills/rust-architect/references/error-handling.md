# Rust Error Handling Reference

## Error Hierarchy

```
Application errors (anyhow) — context, chaining
    └── Domain errors (thiserror) — typed, match-able
            └── Infrastructure errors (sqlx::Error, reqwest::Error, etc.)
```

## Library / Domain Errors with thiserror

```rust
use thiserror::Error;

#[derive(Debug, Error)]
pub enum UserError {
    #[error("user not found: {id}")]
    NotFound { id: Uuid },

    #[error("email already taken: {email}")]
    EmailTaken { email: String },

    #[error("invalid email: {reason}")]
    InvalidEmail { reason: String },

    #[error("password too weak: minimum {min} characters")]
    WeakPassword { min: u8 },

    #[error("database error")]
    Database(#[from] sqlx::Error),
}

#[derive(Debug, Error)]
pub enum AuthError {
    #[error("invalid credentials")]
    InvalidCredentials,

    #[error("token expired")]
    TokenExpired,

    #[error("token invalid")]
    TokenInvalid,

    #[error("insufficient permissions: required role {required}")]
    InsufficientPermissions { required: String },
}
```

## Application Errors with anyhow

```rust
use anyhow::{Context, Result};

// In main.rs and application-level functions
pub async fn startup() -> Result<()> {
    let config = Config::from_env()
        .context("loading configuration from environment")?;

    let pool = PgPool::connect(&config.database_url)
        .await
        .with_context(|| format!("connecting to database: {}", config.database_url))?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("running database migrations")?;

    Ok(())
}
```

## HTTP Error Responses

```rust
use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde_json::json;

impl IntoResponse for UserError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            UserError::NotFound { .. } => {
                (StatusCode::NOT_FOUND, "USER_NOT_FOUND", self.to_string())
            }
            UserError::EmailTaken { .. } => {
                (StatusCode::CONFLICT, "EMAIL_TAKEN", self.to_string())
            }
            UserError::InvalidEmail { .. } | UserError::WeakPassword { .. } => {
                (StatusCode::UNPROCESSABLE_ENTITY, "VALIDATION_ERROR", self.to_string())
            }
            UserError::Database(sqlx::Error::RowNotFound) => {
                (StatusCode::NOT_FOUND, "NOT_FOUND", "not found".to_string())
            }
            UserError::Database(e) if is_unique_violation(e) => {
                (StatusCode::CONFLICT, "CONFLICT", "already exists".to_string())
            }
            UserError::Database(_) => {
                // Never expose DB errors to clients
                tracing::error!(error = %self, "Database error");
                (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", "internal server error".to_string())
            }
        };

        (
            status,
            Json(json!({
                "error": code,
                "message": message,
            })),
        )
            .into_response()
    }
}
```

## Error Propagation Patterns

```rust
// ✅ Simple propagation with ?
pub async fn get_user(pool: &PgPool, id: Uuid) -> Result<User, UserError> {
    sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_optional(pool)
        .await?                              // sqlx::Error → UserError via #[from]
        .ok_or(UserError::NotFound { id })   // Option → Result
}

// ✅ Adding context with .context()
pub async fn load_user_profile(pool: &PgPool, id: Uuid) -> anyhow::Result<Profile> {
    let user = get_user(pool, id)
        .await
        .with_context(|| format!("loading profile for user {id}"))?;

    let prefs = get_preferences(pool, id)
        .await
        .context("loading user preferences")?;

    Ok(Profile { user, prefs })
}

// ✅ Converting between error types
impl From<UserError> for AppError {
    fn from(e: UserError) -> Self {
        match e {
            UserError::NotFound { .. } => AppError::NotFound,
            UserError::EmailTaken { .. } => AppError::Conflict(e.to_string()),
            _ => AppError::Internal(anyhow::anyhow!(e)),
        }
    }
}
```

## Panic Handling in Async Tasks

```rust
// Catch panics in spawned tasks
let handle = tokio::spawn(async move {
    risky_operation().await
});

match handle.await {
    Ok(Ok(result)) => use_result(result),
    Ok(Err(e)) => tracing::error!("Task error: {e}"),
    Err(join_err) => {
        if join_err.is_panic() {
            tracing::error!("Task panicked!");
        }
    }
}

// Set global panic hook for structured logging
std::panic::set_hook(Box::new(|info| {
    let location = info.location().map(|l| format!("{}:{}", l.file(), l.line()));
    tracing::error!(
        location = location.as_deref().unwrap_or("unknown"),
        "Thread panicked: {}",
        info.payload().downcast_ref::<&str>().unwrap_or(&"unknown")
    );
}));
```

## Result Combinators

```rust
// Transform Ok value
result.map(|user| UserResponse::from(user))

// Transform Err value  
result.map_err(|e| AppError::from(e))

// Provide default on Err
result.unwrap_or_default()
result.unwrap_or_else(|_| User::guest())

// Chain operations on Ok
result.and_then(|user| validate_user(user))

// Provide default on None
option.ok_or(AppError::NotFound)?
option.unwrap_or_default()
option.map(transform).unwrap_or(fallback)

// Flatten nested Results
let result: Result<Result<T, E>, E2> = /* ... */;
result.and_then(|inner| inner.map_err(Into::into))
```
