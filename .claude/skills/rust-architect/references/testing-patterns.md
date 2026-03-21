# Rust Testing Patterns Reference

## Unit Tests

```rust
// In src/services/user_service.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_email_accepts_valid_email() {
        assert!(validate_email("alice@example.com").is_ok());
    }

    #[test]
    fn validate_email_rejects_missing_at_sign() {
        let err = validate_email("notanemail").unwrap_err();
        assert!(matches!(err, UserError::InvalidEmail { .. }));
    }

    #[tokio::test]
    async fn create_user_returns_user_with_generated_id() {
        let mock_repo = MockUserRepository::new();
        mock_repo.expect_save().returning(|user| Ok(user.clone()));

        let service = UserService::new(mock_repo);
        let user = service.create("alice@example.com", "Alice").await.unwrap();

        assert_eq!(user.email, "alice@example.com");
        assert!(!user.id.is_nil());
    }
}
```

## Mocking with mockall

```toml
[dev-dependencies]
mockall = "0.13"
```

```rust
use mockall::{automock, predicate::*};

#[automock]
#[async_trait::async_trait]
pub trait UserRepository: Send + Sync {
    async fn find_by_id(&self, id: Uuid) -> Result<Option<User>, RepositoryError>;
    async fn save(&self, user: &User) -> Result<(), RepositoryError>;
}

#[tokio::test]
async fn get_user_returns_not_found_for_missing_user() {
    let mut mock = MockUserRepository::new();
    mock.expect_find_by_id()
        .with(eq(test_user_id()))
        .once()
        .returning(|_| Ok(None));

    let service = UserService::new(Arc::new(mock));
    let result = service.get_user(test_user_id()).await;

    assert!(matches!(result, Err(UserError::NotFound { .. })));
}
```

## Integration Tests with axum-test

```toml
[dev-dependencies]
axum-test = "17"
```

```rust
// tests/users_api.rs
mod common;
use common::TestApp;
use serde_json::json;

#[tokio::test]
async fn create_user_returns_201_with_user() {
    let app = TestApp::new().await;

    let response = app
        .client
        .post("/api/v1/users")
        .json(&json!({
            "email": "alice@example.com",
            "name": "Alice",
            "password": "secure-password-123"
        }))
        .await;

    assert_eq!(response.status_code(), 201);
    let body: serde_json::Value = response.json();
    assert_eq!(body["email"], "alice@example.com");
    assert!(body["id"].is_string());
}

#[tokio::test]
async fn create_user_returns_422_for_invalid_email() {
    let app = TestApp::new().await;

    let response = app
        .client
        .post("/api/v1/users")
        .json(&json!({ "email": "not-an-email", "name": "Alice", "password": "pass123" }))
        .await;

    assert_eq!(response.status_code(), 422);
    let body: serde_json::Value = response.json();
    assert_eq!(body["error"], "VALIDATION_ERROR");
}
```

## Test App Setup

```rust
// tests/common/mod.rs
use axum_test::TestServer;
use sqlx::PgPool;

pub struct TestApp {
    pub client: TestServer,
    pub pool: PgPool,
}

impl TestApp {
    pub async fn new() -> Self {
        let database_url = std::env::var("TEST_DATABASE_URL")
            .unwrap_or_else(|_| "postgres://postgres:postgres@localhost:5432/myapp_test".into());

        let pool = PgPool::connect(&database_url).await.expect("connect test db");
        sqlx::migrate!("./migrations").run(&pool).await.expect("migrate");

        let state = AppState::new(pool.clone(), test_config());
        let app = router::create_router(state);
        let client = TestServer::new(app).unwrap();

        Self { client, pool }
    }
}

fn test_config() -> Config {
    Config {
        port: 0,
        database_url: std::env::var("TEST_DATABASE_URL").unwrap_or_default(),
        jwt_secret: "test-secret-key-minimum-32-characters-long".into(),
        log_level: "debug".into(),
    }
}
```

## Database Tests with sqlx::test

```rust
#[sqlx::test]
async fn test_create_user_db(pool: PgPool) -> sqlx::Result<()> {
    // pool is automatically created and torn down
    // each test runs in an isolated transaction
    let user = db::users::create(&pool, "alice@example.com", "Alice", "hash")
        .await?;

    assert_eq!(user.email, "alice@example.com");

    let fetched = db::users::find_by_id(&pool, user.id).await?;
    assert!(fetched.is_some());
    Ok(())
}
```

## Property-Based Tests with proptest

```toml
[dev-dependencies]
proptest = "1"
```

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn password_hash_is_never_plaintext(password in "[a-zA-Z0-9!@#$]{8,64}") {
        let hash = hash_password(&password).unwrap();
        prop_assert_ne!(hash, password);
        prop_assert!(hash.len() > 20);
    }

    #[test]
    fn user_id_serialization_round_trips(id in any::<[u8; 16]>()) {
        let uuid = Uuid::from_bytes(id);
        let json = serde_json::to_string(&uuid).unwrap();
        let parsed: Uuid = serde_json::from_str(&json).unwrap();
        prop_assert_eq!(uuid, parsed);
    }
}
```

## Benchmarks with criterion

```toml
[dev-dependencies]
criterion = { version = "0.5", features = ["async_tokio"] }

[[bench]]
name = "user_service"
harness = false
```

```rust
// benches/user_service.rs
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use tokio::runtime::Runtime;

fn bench_password_hashing(c: &mut Criterion) {
    let rt = Runtime::new().unwrap();
    let mut group = c.benchmark_group("password_hashing");
    group.throughput(Throughput::Elements(1));

    group.bench_function("argon2id", |b| {
        b.iter(|| {
            hash_password("test-password-123").unwrap()
        })
    });

    group.finish();
}

criterion_group!(benches, bench_password_hashing);
criterion_main!(benches);
```

## Snapshot Testing with insta

```toml
[dev-dependencies]
insta = { version = "1", features = ["json"] }
```

```rust
#[test]
fn test_user_response_serialization() {
    let user = User {
        id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
        email: "alice@example.com".into(),
        name: "Alice".into(),
        created_at: chrono::Utc::now(), // use fixed time in real tests
    };
    let response = UserResponse::from(user);
    insta::assert_json_snapshot!(response);
}
```
