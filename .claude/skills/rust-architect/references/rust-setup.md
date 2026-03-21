# Rust Project Setup Reference

## Cargo.toml (production service)

```toml
[package]
name = "myapp"
version = "0.1.0"
edition = "2021"

[dependencies]
# Async runtime
tokio = { version = "1", features = ["full"] }

# Web framework
axum = { version = "0.8", features = ["macros"] }
tower = "0.5"
tower-http = { version = "0.6", features = ["cors", "trace", "compression-gzip", "timeout", "request-id"] }
axum-extra = { version = "0.10", features = ["typed-header"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Database
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono", "migrate"] }

# Error handling
thiserror = "2"
anyhow = "1"

# Tracing
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }

# Utilities
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
validator = { version = "0.19", features = ["derive"] }
config = "0.14"
tokio-signal = "0.3"

[dev-dependencies]
axum-test = "17"
tokio-test = "0.4"
wiremock = "0.6"

[profile.release]
lto = true
codegen-units = 1
strip = true
opt-level = 3
```

## Project Directory Structure

```
myapp/
├── Cargo.toml
├── Cargo.lock           # Committed for binaries
├── .env.example
├── Dockerfile
├── docker-compose.yml
├── migrations/
│   └── 20240101000001_create_users.sql
├── tests/
│   ├── common/
│   │   └── mod.rs       # Shared test setup (TestApp, etc.)
│   └── users_api.rs     # Integration tests
└── src/
    ├── main.rs
    ├── config.rs
    ├── error.rs
    ├── state.rs
    ├── router.rs
    ├── models/
    │   ├── mod.rs
    │   └── user.rs
    ├── dto/
    │   ├── mod.rs
    │   └── user.rs
    ├── handlers/
    │   ├── mod.rs
    │   ├── health.rs
    │   └── users.rs
    ├── services/
    │   ├── mod.rs
    │   └── user_service.rs
    └── db/
        ├── mod.rs
        └── users.rs
```

## main.rs

```rust
use std::net::SocketAddr;
use anyhow::Context;
use tracing::info;

mod config;
mod db;
mod dto;
mod error;
mod handlers;
mod models;
mod router;
mod services;
mod state;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Init tracing
    let log_format = std::env::var("LOG_FORMAT").unwrap_or_default();
    if log_format == "json" {
        tracing_subscriber::fmt().json().init();
    } else {
        tracing_subscriber::fmt().pretty().init();
    }

    // Load config
    let config = config::Config::from_env().context("loading configuration")?;

    // Database
    let pool = sqlx::PgPool::connect(&config.database_url)
        .await
        .context("connecting to database")?;

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("running migrations")?;

    // App state
    let state = state::AppState::new(pool, config.clone());

    // Router
    let app = router::create_router(state);

    // Bind and serve
    let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .context("binding to address")?;

    info!(%addr, "Server started");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("server error")?;

    info!("Server shut down gracefully");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

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
}
```

## config.rs

```rust
use anyhow::{Context, Result};
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    #[serde(default = "default_port")]
    pub port: u16,
    pub database_url: String,
    pub jwt_secret: String,
    #[serde(default = "default_log_level")]
    pub log_level: String,
}

fn default_port() -> u16 { 8080 }
fn default_log_level() -> String { "info".to_string() }

impl Config {
    pub fn from_env() -> Result<Self> {
        envy::from_env::<Config>().context("reading config from environment variables")
    }
}
```

## state.rs

```rust
use std::sync::Arc;
use sqlx::PgPool;
use crate::config::Config;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub config: Arc<Config>,
}

impl AppState {
    pub fn new(pool: PgPool, config: Config) -> Self {
        Self { pool, config: Arc::new(config) }
    }
}
```

## error.rs

```rust
use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found")]
    NotFound,
    #[error("validation error")]
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
        let (status, code, msg) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "NOT_FOUND", self.to_string()),
            AppError::Validation(e) => (StatusCode::UNPROCESSABLE_ENTITY, "VALIDATION_ERROR", e.to_string()),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "UNAUTHORIZED", self.to_string()),
            AppError::Forbidden => (StatusCode::FORBIDDEN, "FORBIDDEN", self.to_string()),
            AppError::Conflict(m) => (StatusCode::CONFLICT, "CONFLICT", m.clone()),
            AppError::Database(sqlx::Error::RowNotFound) => (StatusCode::NOT_FOUND, "NOT_FOUND", "not found".into()),
            AppError::Database(e) if is_unique_violation(e) => {
                (StatusCode::CONFLICT, "CONFLICT", "already exists".into())
            }
            _ => {
                tracing::error!(error = %self, "Internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "INTERNAL_ERROR", "internal server error".into())
            }
        };
        (status, Json(json!({ "error": code, "message": msg }))).into_response()
    }
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(db) if db.code().as_deref() == Some("23505"))
}
```

## OpenAPI with utoipa

```toml
[dependencies]
utoipa = { version = "5", features = ["axum_extras"] }
utoipa-swagger-ui = { version = "8", features = ["axum"] }
```

```rust
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

#[derive(OpenApi)]
#[openapi(
    paths(handlers::users::list, handlers::users::create, handlers::users::get_by_id),
    components(schemas(dto::user::UserResponse, dto::user::CreateUserRequest, AppError)),
    tags((name = "users", description = "User management"))
)]
struct ApiDoc;

// Add to router:
.merge(SwaggerUi::new("/swagger-ui").url("/api-docs/openapi.json", ApiDoc::openapi()))
```
