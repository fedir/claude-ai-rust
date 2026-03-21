# Claude Code Skills — Rust Development

This directory contains skills for Rust application development. Each skill folder contains:
- `SKILL.md` — loaded by Claude when the skill is invoked
- `README.md` (optional) — human-readable documentation
- `references/` (optional) — detailed reference files linked from SKILL.md

## How Skills Are Used

Claude automatically loads the relevant skill based on context, or you can invoke them explicitly:
```
"Use the rust-web-patterns skill to implement this handler"
"Apply clean-code principles to this module"
"Review this code using rust-code-review"
```

## Available Skills

### Workflow & Quality

| Skill | Description | Trigger |
|-------|-------------|---------|
| `rust-code-review` | Systematic Rust review: ownership, lifetimes, async, unsafe, idiomatic patterns | "review code", "check PR" |
| `clean-code` | DRY/KISS/YAGNI, naming conventions, refactoring for Rust | "clean this code", "refactor" |
| `api-contract-review` | REST API design review: HTTP semantics, versioning, backward compat | "review API", "check endpoints" |

### Architecture & Design

| Skill | Description | Trigger |
|-------|-------------|---------|
| `rust-architect` | Workspace design, crate boundaries, async patterns, production architecture | Designing Rust systems |
| `rust-patterns` | Builder, Newtype, Typestate, Strategy, Observer, Repository in Rust | "implement pattern" |

### Framework & Data

| Skill | Description | Trigger |
|-------|-------------|---------|
| `rust-web-engineer` | Full implementation guide with references for web, data, auth, testing, cloud | Building axum services |
| `rust-web-patterns` | axum patterns: handlers, extractors, state, middleware, error responses | axum questions |
| `sqlx-patterns` | sqlx queries, transactions, migrations, compile-time checked queries | Database questions |
| `tracing-patterns` | Structured logging with `tracing`, spans, MDC, JSON output, OpenTelemetry | Logging/observability |

## Reference Files

Detailed, copy-paste-ready reference implementations:

### rust-architect/references/
| File | Contents |
|------|---------|
| `rust-setup.md` | Cargo.toml, project structure, main.rs, config.rs, state.rs, error.rs |
| `async-patterns.md` | tokio channels, join!, select!, task management, backpressure, streams |
| `error-handling.md` | thiserror, anyhow, error hierarchy, IntoResponse, panic handling |
| `security.md` | argon2 password hashing, JWT, rustls, supply chain (cargo-audit/deny) |
| `testing-patterns.md` | Unit tests, mockall, proptest, criterion benchmarks, snapshot testing |

### rust-web-engineer/references/
| File | Contents |
|------|---------|
| `web.md` | axum router, handlers, extractors, validation, DTOs, pagination |
| `data.md` | sqlx entities, CRUD queries, transactions, migrations, bulk insert |
| `auth.md` | JWT middleware, argon2 hashing, API keys, refresh tokens, RBAC |
| `testing.md` | TestApp setup, axum-test, auth tests, wiremock, sqlx::test |
| `cloud.md` | Dockerfile (cargo-chef), docker-compose, GitHub Actions, Kubernetes |
