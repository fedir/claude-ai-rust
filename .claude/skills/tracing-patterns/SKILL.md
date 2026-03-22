---
name: tracing-patterns
description: Structured logging and distributed tracing for Rust with the tracing ecosystem — subscriber setup, instrument macro, manual spans, axum TraceLayer, request IDs, JSON output, and OpenTelemetry integration.
---

# Tracing Patterns Skill

Structured logging and distributed tracing for Rust with the `tracing` ecosystem, spans, fields, and JSON output.

## When to Use
- User asks about logging, debugging application flow, or analyzing logs
- Setting up observability for a Rust service
- Integrating OpenTelemetry with Rust

---

## Setup

```toml
[dependencies]
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }

# Optional: OpenTelemetry
opentelemetry = "0.27"
opentelemetry-otlp = { version = "0.27", features = ["tonic"] }
tracing-opentelemetry = "0.28"
```

---

## Subscriber Initialization

```rust
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

pub fn init_tracing() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    let formatting_layer = if std::env::var("LOG_FORMAT").as_deref() == Ok("json") {
        // JSON for production
        tracing_subscriber::fmt::layer()
            .json()
            .with_current_span(true)
            .with_span_list(false)
            .boxed()
    } else {
        // Human-readable for development
        tracing_subscriber::fmt::layer()
            .pretty()
            .boxed()
    };

    tracing_subscriber::registry()
        .with(env_filter)
        .with(formatting_layer)
        .init();
}
```

---

## Logging Macros

```rust
use tracing::{debug, error, info, instrument, warn, Span};

// Basic logging with structured fields
info!(user_id = %user.id, email = %user.email, "User created");
warn!(attempt = attempts, max = 3, "Login attempt failed");
error!(error = %e, user_id = %id, "Failed to send email");

// Debug (not logged in production by default)
debug!(query = ?sql_query, params = ?params, "Executing query");

// %value — uses Display trait
// ?value — uses Debug trait
// value — for numeric/bool primitives
```

---

## Instrument Attribute

```rust
use tracing::instrument;

// Automatically creates a span with function name and arguments
#[instrument(skip(pool, password), fields(user_id))]
pub async fn authenticate(
    pool: &PgPool,
    email: &str,
    password: &str,
) -> Result<User, AuthError> {
    let user = find_user_by_email(pool, email).await?;

    // Add fields to current span dynamically
    Span::current().record("user_id", &user.id.to_string());

    verify_password(&user.password_hash, password)?;

    info!("User authenticated successfully");
    Ok(user)
}

// Skip large/sensitive params
#[instrument(skip(self, request_body), err)]
pub async fn handle_request(&self, request_body: Vec<u8>) -> Result<Response, Error> {
    // ...
}
```

---

## Manual Spans

```rust
use tracing::{info_span, Instrument};

// Async spans with .instrument()
pub async fn process_order(order_id: OrderId) -> Result<(), Error> {
    let span = info_span!("process_order", %order_id);
    
    async move {
        info!("Processing order");
        
        let payment = process_payment(order_id)
            .instrument(info_span!("process_payment"))
            .await?;

        info!(payment_id = %payment.id, "Payment processed");
        Ok(())
    }
    .instrument(span)
    .await
}
```

---

## axum Request Tracing

```rust
use tower_http::trace::{DefaultMakeSpan, DefaultOnResponse, TraceLayer};
use tracing::Level;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/users", get(list_users).post(create_user))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(
                    DefaultMakeSpan::new()
                        .level(Level::INFO)
                        .include_headers(false),
                )
                .on_response(
                    DefaultOnResponse::new()
                        .level(Level::INFO)
                        .latency_unit(tower_http::LatencyUnit::Millis),
                ),
        )
        .with_state(state)
}
```

---

## Request ID Propagation

```rust
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use axum::http::HeaderName;

static X_REQUEST_ID: HeaderName = HeaderName::from_static("x-request-id");

pub fn add_request_id_layer(router: Router) -> Router {
    router
        .layer(PropagateRequestIdLayer::new(X_REQUEST_ID.clone()))
        .layer(SetRequestIdLayer::new(X_REQUEST_ID.clone(), MakeRequestUuid))
}

// In middleware: extract request ID and add to tracing span
pub async fn trace_request_id(
    request_id: Option<TypedHeader<headers::XRequestId>>,
    req: Request,
    next: Next,
) -> Response {
    let id = request_id
        .map(|h| h.0.to_string())
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    async move { next.run(req).await }
        .instrument(info_span!("request", request_id = %id))
        .await
}
```

---

## Log Levels Guide

| Level | Use For |
|-------|---------|
| `ERROR` | Unexpected failures that need immediate attention |
| `WARN` | Degraded behavior, recoverable errors, deprecations |
| `INFO` | Service lifecycle, significant business events |
| `DEBUG` | Detailed diagnostic info (disabled in production) |
| `TRACE` | Very fine-grained: loop iterations, raw data |

---

## What to Log / Not Log

**Log:**
- Service startup with key config (port, db pool size)
- Incoming requests (method, path, status, latency)
- Significant business events (user created, order placed)
- All errors with context
- External service calls (duration, result)

**Do NOT log:**
- Passwords, tokens, secrets
- Full request/response bodies (use DEBUG with opt-in)
- PII (emails, phone numbers) — hash if needed for correlation
- High-frequency events in hot paths (use metrics instead)

---

## OpenTelemetry Integration

```rust
use opentelemetry::global;
use opentelemetry_otlp::WithExportConfig;
use tracing_opentelemetry::OpenTelemetryLayer;

pub fn init_telemetry(service_name: &str, otlp_endpoint: &str) -> Result<(), Error> {
    let tracer = opentelemetry_otlp::new_pipeline()
        .tracing()
        .with_exporter(
            opentelemetry_otlp::new_exporter()
                .tonic()
                .with_endpoint(otlp_endpoint),
        )
        .with_trace_config(
            opentelemetry_sdk::trace::Config::default()
                .with_resource(opentelemetry_sdk::Resource::new(vec![
                    opentelemetry::KeyValue::new("service.name", service_name.to_string()),
                ])),
        )
        .install_batch(opentelemetry_sdk::runtime::Tokio)?;

    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(tracing_subscriber::fmt::layer().json())
        .with(OpenTelemetryLayer::new(tracer))
        .init();

    Ok(())
}

pub async fn shutdown_telemetry() {
    global::shutdown_tracer_provider();
}
```

---

## Structured Log Format (JSON production output)

```json
{
  "timestamp": "2024-01-15T10:30:00.000Z",
  "level": "INFO",
  "target": "myapp::handlers::users",
  "message": "User authenticated successfully",
  "span": {
    "name": "authenticate",
    "user_id": "550e8400-e29b-41d4-a716-446655440000"
  },
  "fields": {
    "email": "alice@example.com"
  }
}
```

---

## RUST_LOG Configuration

```bash
# All info, sqlx debug
RUST_LOG=info,sqlx=debug

# Single module trace
RUST_LOG=myapp::handlers=trace

# JSON format
LOG_FORMAT=json RUST_LOG=info ./myapp
```
