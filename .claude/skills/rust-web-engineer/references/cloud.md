# Cloud & DevOps Reference for Rust Services

## Dockerfile (cargo-chef + distroless)

```dockerfile
# syntax=docker/dockerfile:1

# ─── Stage 1: Chef planner ───────────────────────────────────────────────────
FROM rust:1.82-alpine AS planner
RUN apk add --no-cache musl-dev && cargo install cargo-chef
WORKDIR /app
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ─── Stage 2: Dependency cacher ──────────────────────────────────────────────
FROM rust:1.82-alpine AS cacher
RUN apk add --no-cache musl-dev && cargo install cargo-chef
WORKDIR /app
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# ─── Stage 3: Builder ────────────────────────────────────────────────────────
FROM rust:1.82-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /app
COPY . .
COPY --from=cacher /app/target target
COPY --from=cacher /root/.cargo /root/.cargo
RUN cargo build --release --bin myapp && \
    strip target/release/myapp

# ─── Stage 4: Final (distroless) ─────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/target/release/myapp /myapp
EXPOSE 8080
USER nonroot:nonroot
CMD ["/myapp"]
```

## docker-compose.yml (local development)

```yaml
version: "3.9"

services:
  app:
    build: .
    ports:
      - "8080:8080"
    environment:
      DATABASE_URL: postgres://postgres:postgres@db:5432/myapp
      JWT_SECRET: dev-secret-key-minimum-32-characters-long
      RUST_LOG: debug
      LOG_FORMAT: json
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: myapp
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 3s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

volumes:
  postgres_data:
```

## GitHub Actions CI Pipeline

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  CARGO_TERM_COLOR: always
  SQLX_OFFLINE: true

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: myapp_test
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt, clippy

      - name: Cache Rust dependencies
        uses: Swatinem/rust-cache@v2

      - name: Check formatting
        run: cargo fmt --check

      - name: Clippy (deny warnings)
        run: cargo clippy --all-targets --all-features -- -D warnings

      - name: Run tests
        run: cargo test --all-features
        env:
          TEST_DATABASE_URL: postgres://postgres:postgres@localhost:5432/myapp_test

      - name: Security audit
        run: |
          cargo install cargo-audit --quiet
          cargo audit

  build:
    name: Build Docker image
    runs-on: ubuntu-latest
    needs: test

    steps:
      - uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: false
          cache-from: type=gha
          cache-to: type=gha,mode=max
          tags: myapp:${{ github.sha }}
```

## Kubernetes Deployment

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  labels:
    app: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: myapp:latest
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: myapp-secrets
                  key: database-url
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: myapp-secrets
                  key: jwt-secret
            - name: RUST_LOG
              value: info
            - name: LOG_FORMAT
              value: json
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              memory: "64Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
          securityContext:
            runAsNonRoot: true
            runAsUser: 65534
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
      terminationGracePeriodSeconds: 30
```

## Health Endpoints

```rust
use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use serde_json::json;

// Liveness: is the process alive?
pub async fn health() -> impl IntoResponse {
    Json(json!({ "status": "ok", "version": env!("CARGO_PKG_VERSION") }))
}

// Readiness: can it serve traffic? (checks dependencies)
pub async fn ready(State(state): State<AppState>) -> impl IntoResponse {
    match sqlx::query("SELECT 1").execute(&state.pool).await {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({ "status": "ready", "checks": { "database": "ok" } })),
        )
            .into_response(),
        Err(e) => {
            tracing::error!("Readiness check failed: {e}");
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({ "status": "not ready", "checks": { "database": "error" } })),
            )
                .into_response()
        }
    }
}
```

## Environment Variables (.env.example)

```bash
# Server
PORT=8080
LOG_LEVEL=info
LOG_FORMAT=json

# Database
DATABASE_URL=postgres://postgres:postgres@localhost:5432/myapp

# Auth
JWT_SECRET=change-me-to-a-random-32-char-minimum-string

# Optional: external services
# REDIS_URL=redis://localhost:6379
# EMAIL_API_KEY=your-api-key
```
