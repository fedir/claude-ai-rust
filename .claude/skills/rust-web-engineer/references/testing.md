# Web Service Testing Reference

## Test App Helper

```rust
// tests/common/mod.rs
use axum_test::TestServer;
use sqlx::PgPool;
use std::sync::Arc;

pub struct TestApp {
    pub server: TestServer,
    pub pool: PgPool,
}

impl TestApp {
    pub async fn new() -> Self {
        let _ = tracing_subscriber::fmt().with_test_writer().try_init();

        let database_url = std::env::var("TEST_DATABASE_URL")
            .unwrap_or_else(|_| "postgres://postgres:postgres@localhost:5432/myapp_test".into());

        let pool = PgPool::connect(&database_url).await.expect("test db");
        sqlx::migrate!("./migrations").run(&pool).await.expect("migrate");

        let config = Arc::new(Config {
            port: 0,
            database_url: database_url.clone(),
            jwt_secret: secrecy::SecretString::new("test-jwt-secret-minimum-32-characters-long".into()),
            log_level: "debug".into(),
        });

        let state = AppState { pool: pool.clone(), config };
        let router = crate::router::create_router(state);
        let server = TestServer::new(router).expect("test server");

        Self { server, pool }
    }

    /// Create a user and return a valid JWT for auth tests
    pub async fn create_auth_token(&self, email: &str) -> String {
        let response = self.server
            .post("/api/v1/auth/register")
            .json(&serde_json::json!({
                "email": email,
                "name": "Test User",
                "password": "secure-password-123"
            }))
            .await;
        // ... then login and return token
    }
}
```

## Handler Unit Tests with axum-test

```rust
// tests/users_api.rs
mod common;
use common::TestApp;
use serde_json::{json, Value};

#[tokio::test]
async fn get_user_returns_200_with_user() {
    let app = TestApp::new().await;

    // Create user first
    let create = app.server
        .post("/api/v1/users")
        .json(&json!({ "email": "alice@example.com", "name": "Alice", "password": "pass1234" }))
        .await;
    let created: Value = create.json();
    let id = created["id"].as_str().unwrap();

    // Fetch it
    let response = app.server.get(&format!("/api/v1/users/{id}")).await;

    assert_eq!(response.status_code(), 200);
    let body: Value = response.json();
    assert_eq!(body["email"], "alice@example.com");
    assert_eq!(body["name"], "Alice");
}

#[tokio::test]
async fn get_user_returns_404_for_unknown_id() {
    let app = TestApp::new().await;
    let id = uuid::Uuid::new_v4();

    let response = app.server.get(&format!("/api/v1/users/{id}")).await;

    assert_eq!(response.status_code(), 404);
    let body: Value = response.json();
    assert_eq!(body["error"], "NOT_FOUND");
}

#[tokio::test]
async fn create_user_returns_422_for_invalid_email() {
    let app = TestApp::new().await;

    let response = app.server
        .post("/api/v1/users")
        .json(&json!({ "email": "not-email", "name": "Alice", "password": "pass1234" }))
        .await;

    assert_eq!(response.status_code(), 422);
}

#[tokio::test]
async fn create_user_returns_409_for_duplicate_email() {
    let app = TestApp::new().await;
    let body = json!({ "email": "dup@example.com", "name": "User", "password": "pass1234" });

    app.server.post("/api/v1/users").json(&body).await;
    let response = app.server.post("/api/v1/users").json(&body).await;

    assert_eq!(response.status_code(), 409);
}
```

## Auth Tests

```rust
#[tokio::test]
async fn login_returns_token_for_valid_credentials() {
    let app = TestApp::new().await;

    // Register
    app.server
        .post("/api/v1/auth/register")
        .json(&json!({ "email": "alice@example.com", "name": "Alice", "password": "pass1234" }))
        .await;

    // Login
    let response = app.server
        .post("/api/v1/auth/login")
        .json(&json!({ "email": "alice@example.com", "password": "pass1234" }))
        .await;

    assert_eq!(response.status_code(), 200);
    let body: Value = response.json();
    assert!(body["access_token"].is_string());
    assert_eq!(body["token_type"], "Bearer");
}

#[tokio::test]
async fn protected_endpoint_returns_401_without_token() {
    let app = TestApp::new().await;
    let response = app.server.get("/api/v1/users/me").await;
    assert_eq!(response.status_code(), 401);
}

#[tokio::test]
async fn protected_endpoint_returns_200_with_valid_token() {
    let app = TestApp::new().await;
    let token = app.create_auth_token("alice@example.com").await;

    let response = app.server
        .get("/api/v1/users/me")
        .authorization_bearer(&token)
        .await;

    assert_eq!(response.status_code(), 200);
}
```

## Mocking External HTTP with wiremock

```rust
use wiremock::{MockServer, Mock, ResponseTemplate};
use wiremock::matchers::{method, path};

#[tokio::test]
async fn send_welcome_email_calls_email_api() {
    // Start mock server
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/email/send"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "id": "msg_123" })))
        .expect(1)
        .mount(&mock_server)
        .await;

    // Configure app to use mock server URL
    let app = TestApp::new_with_email_url(&mock_server.uri()).await;

    app.server
        .post("/api/v1/auth/register")
        .json(&json!({ "email": "alice@example.com", "name": "Alice", "password": "pass1234" }))
        .await;

    // Verify mock was called
    mock_server.verify().await;
}
```

## Database Tests with sqlx::test

```rust
// Isolated per-test database transaction
#[sqlx::test]
async fn test_find_user_by_email(pool: PgPool) -> sqlx::Result<()> {
    // Insert test data
    sqlx::query!(
        "INSERT INTO users (email, name, password_hash) VALUES ($1, $2, $3)",
        "alice@example.com", "Alice", "hash"
    )
    .execute(&pool)
    .await?;

    let user = db::users::find_by_email(&pool, "alice@example.com").await?;

    assert!(user.is_some());
    assert_eq!(user.unwrap().name, "Alice");
    Ok(())
}

#[sqlx::test]
async fn test_unique_email_constraint(pool: PgPool) -> sqlx::Result<()> {
    db::users::create(&pool, "dup@example.com", "User1", "hash").await?;
    let result = db::users::create(&pool, "dup@example.com", "User2", "hash").await;

    assert!(result.is_err());
    // Check it's a unique violation
    if let Err(sqlx::Error::Database(db_err)) = result {
        assert_eq!(db_err.code().as_deref(), Some("23505"));
    }
    Ok(())
}
```
