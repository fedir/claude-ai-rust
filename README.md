# Claude Code Template for Rust

> Inspired by [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) — completely rewritten for Rust.

A production-grade [Claude Code](https://claude.ai/code) template for building Rust applications. Clone it, start Claude Code, and generate your Rust service with expert-level agents and skills already in place.

## What Is This?

Claude Code can use **agents** (specialized sub-agents for complex tasks) and **skills** (reusable instruction sets loaded on demand). This repository pre-configures both for the full Rust development lifecycle — from architecture and implementation to testing, security, and deployment.

Instead of starting from scratch and coaxing Claude into following Rust best practices, you get a template where idiomatic Rust (edition 2024, native async traits, `std::sync::LazyLock`, proper error handling) is the default from the first prompt.

## Getting Started

```bash
# 1. Clone the template
git clone https://github.com/your-username/claude-ai-rust my-project
cd my-project

# 2. Remove template git history and start fresh
rm -rf .git && git init

# 3. Rename the placeholder package in Cargo.toml
sed -i '' 's/placeholder/my-project/g' Cargo.toml Dockerfile

# 4. Copy environment config
cp .env.example .env

# 5. Open with Claude Code
claude
```

Then just describe what you want to build:

```
Build a REST API for a task management app with PostgreSQL, JWT auth, and pagination.
```

## Repository Structure

```
.
├── .claude
│   ├── agents                        # Specialized sub-agents
│   │   ├── code-reviewer.md
│   │   ├── devops-engineer.md
│   │   ├── docker-expert.md
│   │   ├── kubernetes-specialist.md
│   │   ├── rust-architect.md
│   │   ├── rust-web-engineer.md
│   │   ├── security-engineer.md
│   │   └── test-automator.md
│   ├── settings.local.json           # Allowed CLI permissions
│   └── skills                        # Reusable instruction sets
│       ├── api-contract-review/
│       ├── clean-code/
│       ├── grpc-patterns/
│       ├── rust-architect/
│       │   └── references/           # async-patterns, error-handling,
│       │                             # rust-setup, security, testing,
│       │                             # worker-patterns
│       ├── rust-code-review/
│       ├── rust-patterns/
│       ├── rust-web-engineer/
│       │   └── references/           # auth, cloud, data, testing, web
│       ├── rust-web-patterns/
│       ├── sqlx-patterns/
│       └── tracing-patterns/
├── .env.example
├── .github/workflows/ci.yml          # fmt, clippy, deny, audit, nextest, coverage
├── .gitignore
├── .dockerignore
├── Cargo.toml                        # Rust 2024 edition, [lints], release profile
├── CLAUDE.md                         # Instructions Claude follows in every session
├── clippy.toml
├── deny.toml                         # License policy, dependency bans
├── docker-compose.yml                # Postgres 17 + Redis 7 + app
├── Dockerfile                        # cargo-chef + distroless, <20MB image
└── rustfmt.toml
```

## Agents

Agents are autonomous sub-processes Claude spawns for complex, multi-step tasks. Each has a focused role and its own toolset.

| Agent | Role |
|-------|------|
| `rust-architect` | System design, Cargo workspace layout, async patterns, crate boundaries, performance |
| `rust-web-engineer` | axum REST APIs, handlers, middleware, sqlx integration, auth |
| `code-reviewer` | Ownership, lifetimes, unsafe audits, async correctness, Rust 2024 idioms |
| `test-automator` | cargo-nextest, `#[tokio::test]`, proptest, criterion benchmarks, integration tests |
| `devops-engineer` | CI/CD pipelines, cross-compilation, release automation, build caching |
| `docker-expert` | Multi-stage builds, cargo-chef, distroless images, SBOM, image scanning |
| `kubernetes-specialist` | K8s for Rust: tiny images, low memory requests, instant readiness probes |
| `security-engineer` | `cargo-audit`, `cargo-deny`, unsafe reviews, argon2, rustls, zeroize |

## Skills

Skills are loaded on demand — either automatically by Claude or explicitly in your prompt. Each provides patterns, checklists, and copy-paste-ready reference code.

### Architecture & Design

| Skill | What it provides |
|-------|-----------------|
| `rust-architect` | Workspace structure, dependency selection, error hierarchy, async design, verification gates. References: `rust-setup`, `async-patterns`, `error-handling`, `security`, `testing-patterns`, `worker-patterns` |
| `rust-patterns` | Builder, Newtype, Typestate, Strategy, Observer, Repository. Modern idioms: `let-else`, `#[must_use]`, `LazyLock` |

### Implementation

| Skill | What it provides |
|-------|-----------------|
| `rust-web-engineer` | Full axum service walkthrough. References: `web`, `data`, `auth`, `testing`, `cloud` |
| `rust-web-patterns` | Router composition, handlers, extractors, DTOs, graceful shutdown |
| `grpc-patterns` | tonic server/client, streaming RPCs, interceptors, proto best practices, testing |
| `sqlx-patterns` | Compile-time queries, transactions, `FOR UPDATE SKIP LOCKED`, migrations, pagination |
| `tracing-patterns` | Structured logging, spans, `#[instrument]`, JSON output, OpenTelemetry |

### Quality

| Skill | What it provides |
|-------|-----------------|
| `rust-code-review` | 8-category checklist: ownership, errors, unsafe, async, idiomatic, performance, security, tests |
| `clean-code` | DRY/KISS/YAGNI, naming conventions, guard clauses, refactoring — all in Rust |
| `api-contract-review` | HTTP semantics, versioning, DTO vs model separation, error responses — axum examples |

## Key Standards Enforced

The template is pre-configured to enforce 2026 Rust best practices:

- **Edition 2024** (`edition = "2024"`, `rust-version = "1.85"`)
- **No `async-trait` crate** — native `async fn` in traits (Rust 1.75+)
- **No `once_cell` / `lazy_static`** — `std::sync::LazyLock` from std
- **No `Arc<AppState>` in axum** — `State<AppState>` (axum wraps internally)
- **No `f64` for money** — `i64` cents or `rust_decimal::Decimal`
- **No `unwrap()` in production** — `?` and `thiserror` / `anyhow`
- **`cargo deny`** bans: `openssl-sys`, `lazy_static`, `async-trait`
- **`cargo-nextest`** as the default test runner in CI
- **Distroless/nonroot** final Docker images

## CI Pipeline

The included `.github/workflows/ci.yml` runs on every push and PR:

```
fmt      → cargo fmt --check
clippy   → cargo clippy --all-targets -- -D warnings
deny     → cargo deny check (licenses + bans + advisories)
audit    → cargo audit (CVE scan)
test     → cargo nextest run --all-features
coverage → cargo llvm-cov (uploads to Codecov)
build    → Docker image build (with GHA cache)
```

## Local Development

```bash
# Start dependencies
docker compose up -d db redis

# Run migrations
sqlx migrate run

# Run tests
cargo nextest run

# Run the service
cargo run
```

## Contributing

Issues and PRs are welcome. When contributing, please:

- Follow the existing conventional commit style (`feat:`, `fix:`, `refactor:`, `docs:`)
- Run `cargo fmt --check` and `cargo clippy -- -D warnings` before opening a PR
- Update the relevant skill or reference file if you improve a pattern

## Credits

Inspired by [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) by [@piomin](https://github.com/piomin).

## License

MIT
