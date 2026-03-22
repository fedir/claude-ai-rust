# Rust Architect Skill

Architecture workflows, crate design, async patterns, and production-ready Rust system design.

## When to Use
- Designing Rust system architecture
- Structuring Cargo workspaces and crate boundaries
- Choosing async runtime and libraries
- Solving ownership/lifetime architectural issues

## Reference Files

| Reference | Contents |
|-----------|---------|
| `references/rust-setup.md` | Workspace layout, Cargo.toml, project structure, main.rs |
| `references/async-patterns.md` | tokio patterns, channels, select!, backpressure, task management |
| `references/error-handling.md` | thiserror, anyhow, error hierarchy, IntoResponse |
| `references/security.md` | JWT, argon2, rustls, cargo-audit, input validation |
| `references/testing-patterns.md` | Unit, integration, proptest, criterion, testcontainers |
| `references/worker-patterns.md` | Background jobs, cron scheduling, task queues, graceful shutdown |

---

## Core Architecture Workflow

### Step 1: Understand Requirements
```
- What is the system's primary responsibility?
- Sync or async? I/O-bound or CPU-bound?
- Single binary or workspace with multiple crates?
- Database: PostgreSQL with sqlx? Redis? Both?
- HTTP service with axum? gRPC with tonic? CLI with clap? Worker daemon?
- What are the performance SLAs?
```

### Step 2: Workspace / Crate Structure

For small to medium services — single crate:
```
myapp/
├── Cargo.toml
├── src/
│   ├── main.rs
│   ├── config.rs
│   ├── error.rs
│   ├── state.rs
│   ├── models/      # DB row types
│   ├── dto/         # Request/Response types
│   ├── handlers/    # axum handlers (thin)
│   ├── services/    # Business logic
│   └── db/          # sqlx queries
├── tests/           # Integration tests
└── migrations/      # sqlx migrations
```

For complex systems — Cargo workspace with dependency inheritance:
```toml
# workspace/Cargo.toml
[workspace]
members = ["crates/*"]
resolver = "2"

[workspace.dependencies]
tokio = { version = "1", features = ["full"] }
axum = { version = "0.8", features = ["macros"] }
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono", "migrate"] }
serde = { version = "1", features = ["derive"] }
thiserror = "2"
anyhow = "1"
tracing = "0.1"
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
```

```toml
# crates/api/Cargo.toml — inherits versions from workspace
[dependencies]
tokio = { workspace = true }
axum = { workspace = true }
sqlx = { workspace = true }
serde = { workspace = true }
```

```
workspace/
├── Cargo.toml        # [workspace] with shared [workspace.dependencies]
├── crates/
│   ├── domain/       # Core types, traits, no I/O
│   ├── infra/        # DB, external APIs (implements domain traits)
│   ├── api/          # axum router, handlers
│   ├── worker/       # Background job processor
│   └── cli/          # CLI entry point
└── tests/            # Integration tests across crates
```

### Step 3: Dependency Selection

| Need | Recommended Crate |
|------|------------------|
| Async runtime | `tokio` (full features) |
| Web framework | `axum` + `tower-http` |
| gRPC | `tonic` + `prost` |
| Database | `sqlx` (PostgreSQL) |
| Serialization | `serde` + `serde_json` |
| Error handling (lib) | `thiserror` |
| Error handling (app) | `anyhow` |
| Logging/tracing | `tracing` + `tracing-subscriber` |
| Configuration | `config` (files + env vars + defaults) |
| HTTP client | `reqwest` |
| Auth/JWT | `jsonwebtoken` |
| Password hashing | `argon2` |
| UUID | `uuid` (v4 + serde features) |
| DateTime | `chrono` (serde feature) |
| Validation | `validator` (derive) or `garde` (derive) |
| CLI | `clap` (derive feature) |

### Step 4: Error Architecture

```rust
// Library crates: typed errors
#[derive(Debug, thiserror::Error)]
pub enum DomainError {
    #[error("user not found: {0}")]
    UserNotFound(Uuid),
    #[error("email already taken: {0}")]
    EmailTaken(String),
    #[error("database error")]
    Database(#[from] sqlx::Error),
}

// HTTP layer: map to responses
// See canonical AppError in references/rust-setup.md
impl IntoResponse for DomainError {
    fn into_response(self) -> Response {
        // map to StatusCode + JSON body
    }
}

// Application code: anyhow for context
fn load_and_process() -> anyhow::Result<()> {
    let config = load_config().context("loading config")?;
    // ...
}
```

### Step 5: Async Design

```
- Use tokio::spawn for independent concurrent tasks
- Use tokio::join! for concurrent dependent results
- Use tokio::select! for racing futures
- Use channels (mpsc, broadcast, oneshot) for communication
- Never block the async runtime (use spawn_blocking for CPU work)
- Set TOKIO_WORKER_THREADS for production tuning
- Use native async fn in traits — do NOT use the async-trait crate
```

### Step 6: Self-Verification Gates

Before calling architecture done, verify:
- [ ] `cargo fmt --check` passes
- [ ] `cargo clippy -- -D warnings` clean
- [ ] `cargo deny check` passes
- [ ] `cargo test` passes (or `cargo nextest run`)
- [ ] `cargo audit` no vulnerabilities
- [ ] Docker image builds and service starts
- [ ] Health endpoint responds
- [ ] Database migrations run without error

---

## MUST DO

- Use `Result<T, E>` everywhere — no `unwrap()` in production
- Model domain with enums before reaching for generics
- Keep handlers thin — business logic in services
- Use `State<AppState>` — axum wraps in `Arc` internally; do NOT double-wrap
- Pin dependencies in `Cargo.lock` (commit it for binaries)
- Use `#[instrument]` on service functions for tracing
- Add `#[must_use]` on functions whose return value should not be ignored
- Use `let ... else { return }` for early exits (Rust 2024 idiom)
- Use `std::sync::LazyLock` for lazy statics (NOT `once_cell` or `lazy_static`)

## MUST NOT DO

- Do not use `std::sync::Mutex` across `.await` points
- Do not use blocking I/O (`std::fs`, `std::net`) in async functions
- Do not return `Box<dyn Error>` from library functions
- Do not use `unwrap()` / `expect()` in handlers or services
- Do not put business logic in axum handlers
- Do not ignore `JoinHandle` from `tokio::spawn` (task leaks)
- Do not use `async-trait` crate — native async fn in traits since Rust 1.75
- Do not use `once_cell` or `lazy_static` — use `std::sync::LazyLock`
