# Claude Code Template for Rust Application

This template provides a structured starting point for Rust applications, optimized for Claude AI's code generation capabilities. It includes essential configurations, agents, and skills to streamline development and enhance productivity.

The idea behind this template is that you can just clone this repository and use it to generate the Rust app you want with Claude Code.

```
.
├── .claude
│   ├── agents
│   │   ├── code-reviewer.md
│   │   ├── devops-engineer.md
│   │   ├── docker-expert.md
│   │   ├── kubernetes-specialist.md
│   │   ├── rust-architect.md
│   │   ├── rust-web-engineer.md
│   │   ├── security-engineer.md
│   │   └── test-automator.md
│   ├── settings.local.json
│   └── skills
│       ├── README.md
│       ├── api-contract-review
│       │   └── SKILL.md
│       ├── clean-code
│       │   └── SKILL.md
│       ├── grpc-patterns
│       │   └── SKILL.md
│       ├── rust-architect
│       │   ├── SKILL.md
│       │   └── references
│       │       ├── async-patterns.md
│       │       ├── error-handling.md
│       │       ├── rust-setup.md
│       │       ├── security.md
│       │       ├── testing-patterns.md
│       │       └── worker-patterns.md
│       ├── rust-code-review
│       │   └── SKILL.md
│       ├── rust-patterns
│       │   └── SKILL.md
│       ├── rust-web-engineer
│       │   ├── SKILL.md
│       │   └── references
│       │       ├── auth.md
│       │       ├── cloud.md
│       │       ├── data.md
│       │       ├── testing.md
│       │       └── web.md
│       ├── rust-web-patterns
│       │   └── SKILL.md
│       ├── sqlx-patterns
│       │   └── SKILL.md
│       └── tracing-patterns
│           └── SKILL.md
├── .env.example
├── .github
│   └── workflows
│       └── ci.yml
├── .gitignore
├── .dockerignore
├── Cargo.toml
├── CLAUDE.md
├── clippy.toml
├── deny.toml
├── docker-compose.yml
├── Dockerfile
├── README.md
└── rustfmt.toml
```

## Included Agents

| Agent | Purpose |
|-------|---------|
| `rust-architect` | Systems architecture, ownership patterns, async design, performance |
| `rust-web-engineer` | axum microservices, REST APIs, middleware, async handlers |
| `code-reviewer` | Rust-focused review: ownership, lifetimes, unsafe, error handling |
| `devops-engineer` | CI/CD with cargo, cross-compilation, release automation |
| `docker-expert` | Multi-stage Rust builds, cargo-chef, distroless images |
| `kubernetes-specialist` | K8s for Rust services: tiny images, low memory, instant startup |
| `security-engineer` | Rust security: supply chain, unsafe audits, cargo-audit/deny |
| `test-automator` | cargo-nextest, criterion benchmarks, proptest, integration testing |

## Included Skills

| Skill | Purpose |
|-------|---------|
| `rust-architect` | Architecture workflows + references (setup, async, errors, security, testing, workers) |
| `rust-web-engineer` | Full web implementation guide + references (web, data, auth, testing, cloud) |
| `rust-code-review` | Systematic review: ownership, lifetimes, unsafe, async, Rust 2024 idioms |
| `rust-patterns` | Builder, Newtype, Typestate, Strategy, Observer, Repository + modern idioms |
| `rust-web-patterns` | axum handlers, extractors, middleware, shared state, error responses |
| `grpc-patterns` | tonic server/client, streaming RPCs, interceptors, proto best practices |
| `sqlx-patterns` | Compile-time queries, transactions, migrations, connection pools |
| `tracing-patterns` | Structured logging with `tracing`, spans, JSON output, OpenTelemetry |
| `clean-code` | DRY/KISS/YAGNI, naming, function design — adapted for Rust idioms |
| `api-contract-review` | REST API auditing with axum examples: HTTP semantics, versioning, compat |

## Project Configuration

| File | Purpose |
|------|---------|
| `Cargo.toml` | Rust 2024 edition, dependencies, clippy lints, release profile |
| `rustfmt.toml` | Code formatting: edition 2024, import grouping, 100 char width |
| `clippy.toml` | Lint tuning: complexity threshold, argument limits |
| `deny.toml` | Dependency policy: license allowlist, bans (openssl, lazy_static, async-trait) |
| `Dockerfile` | Multi-stage build: cargo-chef + distroless, nonroot, <20MB |
| `docker-compose.yml` | Local dev: Postgres 17 + Redis 7 + app with health checks |
| `.github/workflows/ci.yml` | CI: fmt, clippy, deny, audit, nextest, llvm-cov, Docker build |
| `.env.example` | All environment variables documented |
