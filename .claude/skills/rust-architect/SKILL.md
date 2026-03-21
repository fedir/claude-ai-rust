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

---

## Core Architecture Workflow

### Step 1: Understand Requirements
```
- What is the system's primary responsibility?
- Sync or async? I/O-bound or CPU-bound?
- Single binary or workspace with multiple crates?
- Database: PostgreSQL with sqlx? Redis? Both?
- HTTP service with axum? CLI with clap? Worker daemon?
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

For complex systems — Cargo workspace:
```
workspace/
├── Cargo.toml        # [workspace] members = [...]
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
| Database | `sqlx` (PostgreSQL) |
| Serialization | `serde` + `serde_json` |
| Error handling (lib) | `thiserror` |
| Error handling (app) | `anyhow` |
| Logging/tracing | `tracing` + `tracing-subscriber` |
| Configuration | `config` or `envy` |
| HTTP client | `reqwest` |
| Auth/JWT | `jsonwebtoken` |
| Password hashing | `argon2` |
| UUID | `uuid` (v4 + serde features) |
| DateTime | `chrono` (serde feature) |
| Validation | `validator` (derive feature) |
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
```

### Step 6: Self-Verification Gates

Before calling architecture done, verify:
- [ ] `cargo build --release` succeeds
- [ ] `cargo clippy -- -D warnings` clean
- [ ] `cargo test` passes
- [ ] `cargo audit` no vulnerabilities
- [ ] Docker image builds and service starts
- [ ] Health endpoint responds
- [ ] Database migrations run without error

---

## MUST DO

- Use `Result<T, E>` everywhere — no `unwrap()` in production
- Model domain with enums before reaching for generics
- Keep handlers thin — business logic in services
- Use `Arc<AppState>` for shared service state
- Pin dependencies in `Cargo.lock` (commit it for binaries)
- Use `#[instrument]` on service functions for tracing

## MUST NOT DO

- Do not use `std::sync::Mutex` across `.await` points
- Do not use blocking I/O (`std::fs`, `std::net`) in async functions
- Do not return `Box<dyn Error>` from library functions
- Do not use `unwrap()` / `expect()` in handlers or services
- Do not put business logic in axum handlers
- Do not ignore `JoinHandle` from `tokio::spawn` (task leaks)
