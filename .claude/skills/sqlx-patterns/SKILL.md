# sqlx Patterns Skill

sqlx query patterns, compile-time checked queries, connection pools, transactions, and migrations for Rust.

## When to Use
- User has sqlx queries, connection pool issues, or migration problems
- Designing database access layer for Rust application
- Optimizing database queries in async Rust

---

## Setup

```toml
# Cargo.toml
[dependencies]
sqlx = { version = "0.8", features = ["runtime-tokio", "postgres", "uuid", "chrono", "migrate", "json"] }
```

```bash
# Install sqlx-cli
cargo install sqlx-cli --no-default-features --features postgres

# Create and run migrations
sqlx migrate add create_users_table
sqlx migrate run
```

```rust
// Database connection pool setup
use sqlx::PgPool;

pub async fn create_pool(database_url: &str) -> Result<PgPool, sqlx::Error> {
    PgPool::connect_with(
        sqlx::postgres::PgConnectOptions::from_str(database_url)?
            .application_name("myapp")
    )
    .await
}

// Or with full options
let pool = sqlx::postgres::PgPoolOptions::new()
    .max_connections(20)
    .min_connections(2)
    .acquire_timeout(std::time::Duration::from_secs(3))
    .connect(database_url)
    .await?;
```

---

## Compile-Time Checked Queries

Requires `DATABASE_URL` env var at compile time (or `.sqlx/` prepared queries for offline mode).

```rust
// Fetch single row as typed struct
#[derive(Debug, sqlx::FromRow)]
pub struct User {
    pub id: uuid::Uuid,
    pub email: String,
    pub name: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}

// query_as! — compile-time checked, returns typed struct
pub async fn find_user_by_id(pool: &PgPool, id: Uuid) -> Result<Option<User>, sqlx::Error> {
    sqlx::query_as!(
        User,
        "SELECT id, email, name, created_at FROM users WHERE id = $1",
        id
    )
    .fetch_optional(pool)
    .await
}

// query! — compile-time checked, returns anonymous struct
pub async fn count_users(pool: &PgPool) -> Result<i64, sqlx::Error> {
    let row = sqlx::query!("SELECT COUNT(*) as count FROM users")
        .fetch_one(pool)
        .await?;
    Ok(row.count.unwrap_or(0))
}

// Insert with returning
pub async fn create_user(pool: &PgPool, email: &str, name: &str) -> Result<User, sqlx::Error> {
    sqlx::query_as!(
        User,
        "INSERT INTO users (id, email, name) VALUES ($1, $2, $3) RETURNING id, email, name, created_at",
        Uuid::new_v4(),
        email,
        name
    )
    .fetch_one(pool)
    .await
}
```

---

## Transactions

```rust
pub async fn transfer_funds(
    pool: &PgPool,
    from: Uuid,
    to: Uuid,
    amount: i64,
) -> Result<(), AppError> {
    let mut tx = pool.begin().await?;

    // Debit
    let rows = sqlx::query!(
        "UPDATE accounts SET balance = balance - $1 WHERE id = $2 AND balance >= $1",
        amount,
        from
    )
    .execute(&mut *tx)
    .await?;

    if rows.rows_affected() == 0 {
        tx.rollback().await?;
        return Err(AppError::InsufficientFunds);
    }

    // Credit
    sqlx::query!(
        "UPDATE accounts SET balance = balance + $1 WHERE id = $2",
        amount,
        to
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(())
}
```

---

## Pagination

```rust
#[derive(Debug)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub total: i64,
    pub page: i64,
    pub per_page: i64,
}

pub async fn list_users(
    pool: &PgPool,
    page: i64,
    per_page: i64,
) -> Result<Page<User>, sqlx::Error> {
    let offset = (page - 1) * per_page;

    let (items, total) = tokio::try_join!(
        sqlx::query_as!(
            User,
            "SELECT id, email, name, created_at FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2",
            per_page,
            offset
        )
        .fetch_all(pool),
        async {
            sqlx::query!("SELECT COUNT(*) as count FROM users")
                .fetch_one(pool)
                .await
                .map(|r| r.count.unwrap_or(0))
        }
    )?;

    Ok(Page { items, total, page, per_page })
}
```

---

## Dynamic Queries with QueryBuilder

When filters are conditional (use `query_builder` to avoid SQL injection):

```rust
use sqlx::QueryBuilder;

pub async fn search_users(
    pool: &PgPool,
    email_filter: Option<&str>,
    active_only: bool,
) -> Result<Vec<User>, sqlx::Error> {
    let mut builder = QueryBuilder::new(
        "SELECT id, email, name, created_at FROM users WHERE 1=1"
    );

    if let Some(email) = email_filter {
        builder.push(" AND email ILIKE ").push_bind(format!("%{email}%"));
    }

    if active_only {
        builder.push(" AND active = true");
    }

    builder.push(" ORDER BY created_at DESC");

    builder
        .build_query_as::<User>()
        .fetch_all(pool)
        .await
}
```

---

## Offline Mode (CI without database)

```bash
# Prepare query metadata for offline compilation
cargo sqlx prepare -- --all-targets

# Commit .sqlx/ directory to git
# Set in CI:
export SQLX_OFFLINE=true
```

---

## Migrations

```sql
-- migrations/20240101000001_create_users.sql
CREATE TABLE users (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email       TEXT NOT NULL UNIQUE,
    name        TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    active      BOOLEAN NOT NULL DEFAULT true,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users(email);
```

```rust
// Run migrations at startup
sqlx::migrate!("./migrations").run(&pool).await?;
```

---

## Error Mapping to HTTP

```rust
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("not found")]
    NotFound,
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("database error")]
    Database(#[from] sqlx::Error),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, self.to_string()),
            AppError::Conflict(msg) => (StatusCode::CONFLICT, msg.clone()),
            AppError::Database(sqlx::Error::RowNotFound) => (StatusCode::NOT_FOUND, "not found".into()),
            AppError::Database(e) if is_unique_violation(e) => {
                (StatusCode::CONFLICT, "already exists".into())
            }
            AppError::Database(_) => {
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".into())
            }
        };
        (status, message).into_response()
    }
}

fn is_unique_violation(e: &sqlx::Error) -> bool {
    matches!(e, sqlx::Error::Database(db) if db.code().as_deref() == Some("23505"))
}
```

---

## Testing with sqlx

```rust
// Use #[sqlx::test] — creates isolated transaction per test, auto-rollback
#[sqlx::test]
async fn test_create_user(pool: PgPool) -> sqlx::Result<()> {
    let user = create_user(&pool, "alice@example.com", "Alice").await?;
    assert_eq!(user.email, "alice@example.com");

    let fetched = find_user_by_id(&pool, user.id).await?;
    assert!(fetched.is_some());
    Ok(())
}
```

---

## Performance Checklist

- [ ] `PgPoolOptions` with appropriate `max_connections` (default: 10)
- [ ] Indexes on columns used in `WHERE` and `JOIN`
- [ ] `fetch_optional` for single rows (not `fetch_all` + check len)
- [ ] `tokio::try_join!` for parallel independent queries
- [ ] `fetch` stream for large result sets (not `fetch_all`)
- [ ] Batch inserts with `UNNEST` for bulk operations
- [ ] `EXPLAIN ANALYZE` for slow queries
- [ ] Connection pool `acquire_timeout` set to fail fast

```rust
// Batch insert with UNNEST (fast)
pub async fn bulk_insert_users(pool: &PgPool, users: &[(String, String)]) -> Result<(), sqlx::Error> {
    let (emails, names): (Vec<_>, Vec<_>) = users.iter().cloned().unzip();
    sqlx::query!(
        "INSERT INTO users (email, name) SELECT * FROM UNNEST($1::text[], $2::text[])",
        &emails,
        &names
    )
    .execute(pool)
    .await?;
    Ok(())
}
```
