# Data Access Reference (sqlx)

## Entity / Model Types

```rust
use sqlx::FromRow;
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Clone, FromRow)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub name: String,
    pub password_hash: String,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub version: i64, // optimistic locking
}

#[derive(Debug, Clone, sqlx::Type, serde::Serialize, serde::Deserialize, PartialEq)]
#[sqlx(type_name = "user_status", rename_all = "lowercase")]
pub enum UserStatus {
    Active,
    Inactive,
    Suspended,
}
```

## Migration Files

```sql
-- migrations/20240101000001_create_users.sql
CREATE TYPE user_status AS ENUM ('active', 'inactive', 'suspended');

CREATE TABLE users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    status        user_status NOT NULL DEFAULT 'active',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    version       BIGINT NOT NULL DEFAULT 1
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_status ON users(status);

-- Trigger: auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

## Repository Functions (db/users.rs)

```rust
use sqlx::{PgPool, QueryBuilder};
use uuid::Uuid;
use crate::models::user::{User, UserStatus};

pub async fn find_by_id(pool: &PgPool, id: Uuid) -> Result<Option<User>, sqlx::Error> {
    sqlx::query_as!(User, "SELECT * FROM users WHERE id = $1", id)
        .fetch_optional(pool)
        .await
}

pub async fn find_by_email(pool: &PgPool, email: &str) -> Result<Option<User>, sqlx::Error> {
    sqlx::query_as!(User, "SELECT * FROM users WHERE email = $1", email)
        .fetch_optional(pool)
        .await
}

pub async fn create(
    pool: &PgPool,
    email: &str,
    name: &str,
    password_hash: &str,
) -> Result<User, sqlx::Error> {
    sqlx::query_as!(
        User,
        "INSERT INTO users (email, name, password_hash) VALUES ($1, $2, $3) RETURNING *",
        email, name, password_hash
    )
    .fetch_one(pool)
    .await
}

pub async fn update_name(
    pool: &PgPool,
    id: Uuid,
    name: &str,
    expected_version: i64,
) -> Result<Option<User>, sqlx::Error> {
    // Optimistic locking with version check
    sqlx::query_as!(
        User,
        "UPDATE users SET name = $1, version = version + 1
         WHERE id = $2 AND version = $3
         RETURNING *",
        name, id, expected_version
    )
    .fetch_optional(pool)
    .await
}

pub async fn delete(pool: &PgPool, id: Uuid) -> Result<bool, sqlx::Error> {
    let result = sqlx::query!("DELETE FROM users WHERE id = $1", id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() > 0)
}

pub async fn list(
    pool: &PgPool,
    page: i64,
    per_page: i64,
    status_filter: Option<UserStatus>,
) -> Result<(Vec<User>, i64), sqlx::Error> {
    let offset = (page - 1) * per_page;

    // Build dynamic query
    let mut count_query = QueryBuilder::new("SELECT COUNT(*) FROM users WHERE 1=1");
    let mut list_query = QueryBuilder::new("SELECT * FROM users WHERE 1=1");

    if let Some(ref status) = status_filter {
        count_query.push(" AND status = ").push_bind(status);
        list_query.push(" AND status = ").push_bind(status);
    }

    list_query.push(" ORDER BY created_at DESC LIMIT ")
        .push_bind(per_page)
        .push(" OFFSET ")
        .push_bind(offset);

    let (users, total) = tokio::try_join!(
        list_query.build_query_as::<User>().fetch_all(pool),
        async {
            count_query
                .build_query_scalar::<i64>()
                .fetch_one(pool)
                .await
        }
    )?;

    Ok((users, total))
}
```

## Transactions

```rust
pub async fn transfer(
    pool: &PgPool,
    from_id: Uuid,
    to_id: Uuid,
    amount: i64,
) -> Result<(), TransferError> {
    let mut tx = pool.begin().await?;

    let from = sqlx::query_as!(
        Account,
        "SELECT * FROM accounts WHERE id = $1 FOR UPDATE",
        from_id
    )
    .fetch_optional(&mut *tx)
    .await?
    .ok_or(TransferError::AccountNotFound(from_id))?;

    if from.balance < amount {
        return Err(TransferError::InsufficientFunds { available: from.balance, required: amount });
    }

    sqlx::query!("UPDATE accounts SET balance = balance - $1 WHERE id = $2", amount, from_id)
        .execute(&mut *tx).await?;

    sqlx::query!("UPDATE accounts SET balance = balance + $1 WHERE id = $2", amount, to_id)
        .execute(&mut *tx).await?;

    sqlx::query!(
        "INSERT INTO transfers (from_account_id, to_account_id, amount) VALUES ($1, $2, $3)",
        from_id, to_id, amount
    )
    .execute(&mut *tx).await?;

    tx.commit().await?;
    Ok(())
}
```

## Bulk Insert with UNNEST

```rust
pub async fn bulk_create(
    pool: &PgPool,
    users: &[(String, String)], // (email, name)
) -> Result<Vec<User>, sqlx::Error> {
    let (emails, names): (Vec<String>, Vec<String>) = users.iter().cloned().unzip();

    sqlx::query_as!(
        User,
        "INSERT INTO users (email, name, password_hash)
         SELECT email, name, '' FROM UNNEST($1::text[], $2::text[]) AS t(email, name)
         RETURNING *",
        &emails,
        &names
    )
    .fetch_all(pool)
    .await
}
```
