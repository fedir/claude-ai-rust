# Claude Code Template for Rust Application

This template provides a structured starting point for Rust applications, optimized for Claude AI's code generation capabilities. It includes essential configurations, agents, and skills to streamline development and enhance productivity.

The idea behind this template is that you can just clone this repository and use it to generate the Rust app you want with Claude Code.

```shell
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
│       ├── rust-architect
│       │   ├── SKILL.md
│       │   └── references
│       │       ├── async-patterns.md
│       │       ├── error-handling.md
│       │       ├── rust-setup.md
│       │       ├── security.md
│       │       └── testing-patterns.md
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
├── Cargo.toml
├── CLAUDE.md
└── README.md
```

## Included Agents

| Agent | Purpose |
|-------|---------|
| `rust-architect` | Systems architecture, ownership patterns, async design, performance |
| `rust-web-engineer` | Axum microservices, REST APIs, middleware, async handlers |
| `code-reviewer` | Rust-focused review: ownership, lifetimes, unsafe, error handling |
| `devops-engineer` | CI/CD with cargo, cross-compilation, release automation |
| `docker-expert` | Multi-stage Rust builds, minimal images, production containers |
| `kubernetes-specialist` | Kubernetes workload orchestration, health checks, secrets |
| `security-engineer` | Rust security: supply chain, unsafe audits, crypto patterns |
| `test-automator` | cargo test, criterion benchmarks, proptest, integration testing |

## Included Skills

| Skill | Purpose |
|-------|---------|
| `rust-architect` | Architecture workflows with references for setup, async, errors, security, testing |
| `rust-web-engineer` | Full web implementation guide with references for web, data, auth, testing, cloud |
| `rust-code-review` | Systematic Rust review: ownership, lifetimes, unsafe, concurrency, idiomatic code |
| `rust-patterns` | Builder, Newtype, Typestate, State Machine, Strategy, Observer in Rust |
| `rust-web-patterns` | Axum patterns: handlers, extractors, middleware, shared state, error responses |
| `sqlx-patterns` | sqlx query patterns, migrations, connection pools, compile-time checked queries |
| `tracing-patterns` | Structured logging with `tracing`, spans, MDC, JSON output |
| `clean-code` | DRY/KISS/YAGNI, naming, function design — adapted for Rust idioms |
| `api-contract-review` | REST API auditing: HTTP semantics, versioning, backward compatibility |
