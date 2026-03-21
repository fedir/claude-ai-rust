# Rust Design Patterns Skill

Common Rust design patterns with idiomatic implementations: Builder, Newtype, Typestate, Strategy, Observer, and more.

## When to Use
- User asks "implement pattern", "use builder", "state machine"
- Designing extensible Rust components
- Enforcing invariants at compile time

---

## Builder Pattern

```rust
use uuid::Uuid;

#[derive(Debug)]
pub struct Email(String);

#[derive(Debug)]
pub struct User {
    pub id: Uuid,
    pub name: String,
    pub email: Email,
    pub age: Option<u32>,
}

#[derive(Default)]
pub struct UserBuilder {
    name: Option<String>,
    email: Option<String>,
    age: Option<u32>,
}

impl UserBuilder {
    pub fn name(mut self, name: impl Into<String>) -> Self {
        self.name = Some(name.into());
        self
    }

    pub fn email(mut self, email: impl Into<String>) -> Self {
        self.email = Some(email.into());
        self
    }

    pub fn age(mut self, age: u32) -> Self {
        self.age = Some(age);
        self
    }

    pub fn build(self) -> Result<User, BuildError> {
        Ok(User {
            id: Uuid::new_v4(),
            name: self.name.ok_or(BuildError::MissingField("name"))?,
            email: Email(self.email.ok_or(BuildError::MissingField("email"))?),
            age: self.age,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum BuildError {
    #[error("missing required field: {0}")]
    MissingField(&'static str),
}

// Usage
let user = UserBuilder::default()
    .name("Alice")
    .email("alice@example.com")
    .build()?;
```

---

## Newtype Pattern

Enforce type safety at zero runtime cost:

```rust
// Prevent mixing up IDs of different types
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct UserId(Uuid);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct OrderId(Uuid);

impl UserId {
    pub fn new() -> Self { Self(Uuid::new_v4()) }
    pub fn inner(self) -> Uuid { self.0 }
}

impl From<Uuid> for UserId {
    fn from(id: Uuid) -> Self { Self(id) }
}

// Now this won't compile — type safety enforced:
// fn get_order(id: UserId) -> Order { ... }
// get_order(order_id); // ERROR: expected UserId, found OrderId
```

---

## Typestate Pattern

Enforce state machine transitions at compile time:

```rust
use std::marker::PhantomData;

// States as zero-sized types
pub struct Draft;
pub struct Published;
pub struct Archived;

pub struct Article<State> {
    title: String,
    content: String,
    _state: PhantomData<State>,
}

impl Article<Draft> {
    pub fn new(title: impl Into<String>, content: impl Into<String>) -> Self {
        Article {
            title: title.into(),
            content: content.into(),
            _state: PhantomData,
        }
    }

    pub fn publish(self) -> Article<Published> {
        Article { title: self.title, content: self.content, _state: PhantomData }
    }
}

impl Article<Published> {
    pub fn archive(self) -> Article<Archived> {
        Article { title: self.title, content: self.content, _state: PhantomData }
    }

    pub fn title(&self) -> &str { &self.title }
}

// article.archive() only callable on Published — compile-time guarantee
let draft = Article::<Draft>::new("Rust Patterns", "...");
let published = draft.publish();
let _archived = published.archive();
// draft.archive(); // ERROR: method not found in `Article<Draft>`
```

---

## Strategy Pattern

```rust
pub trait PricingStrategy: Send + Sync {
    fn calculate(&self, base_price: f64, quantity: u32) -> f64;
}

pub struct RegularPricing;
pub struct BulkPricing { pub threshold: u32, pub discount: f64 }
pub struct MemberPricing { pub discount_pct: f64 }

impl PricingStrategy for RegularPricing {
    fn calculate(&self, base_price: f64, quantity: u32) -> f64 {
        base_price * quantity as f64
    }
}

impl PricingStrategy for BulkPricing {
    fn calculate(&self, base_price: f64, quantity: u32) -> f64 {
        let total = base_price * quantity as f64;
        if quantity >= self.threshold { total * (1.0 - self.discount) } else { total }
    }
}

pub struct Cart {
    items: Vec<(f64, u32)>,
    strategy: Box<dyn PricingStrategy>,
}

impl Cart {
    pub fn new(strategy: impl PricingStrategy + 'static) -> Self {
        Cart { items: vec![], strategy: Box::new(strategy) }
    }

    pub fn total(&self) -> f64 {
        self.items.iter().map(|(p, q)| self.strategy.calculate(*p, *q)).sum()
    }
}

// With enum dispatch (preferred for closed set of strategies — no heap allocation):
pub enum Pricing { Regular, Bulk { threshold: u32 }, Member { discount: f64 } }

impl Pricing {
    pub fn calculate(&self, price: f64, qty: u32) -> f64 {
        match self {
            Self::Regular => price * qty as f64,
            Self::Bulk { threshold } if qty >= *threshold => price * qty as f64 * 0.9,
            Self::Bulk { .. } => price * qty as f64,
            Self::Member { discount } => price * qty as f64 * (1.0 - discount),
        }
    }
}
```

---

## Observer Pattern with Channels

```rust
use tokio::sync::broadcast;

#[derive(Debug, Clone)]
pub enum DomainEvent {
    UserCreated { id: UserId, email: String },
    OrderPlaced { id: OrderId, user_id: UserId },
}

pub struct EventBus {
    sender: broadcast::Sender<DomainEvent>,
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self { sender }
    }

    pub fn publish(&self, event: DomainEvent) {
        // Ignore send error (no subscribers is fine)
        let _ = self.sender.send(event);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<DomainEvent> {
        self.sender.subscribe()
    }
}

// Subscriber
async fn email_notification_handler(mut rx: broadcast::Receiver<DomainEvent>) {
    loop {
        match rx.recv().await {
            Ok(DomainEvent::UserCreated { id, email }) => {
                // send welcome email
                tracing::info!(%id, %email, "Sending welcome email");
            }
            Ok(_) => {} // ignore other events
            Err(broadcast::error::RecvError::Lagged(n)) => {
                tracing::warn!("Notification handler lagged by {} events", n);
            }
            Err(broadcast::error::RecvError::Closed) => break,
        }
    }
}
```

---

## Repository Pattern

```rust
use async_trait::async_trait;

#[async_trait]
pub trait UserRepository: Send + Sync {
    async fn find_by_id(&self, id: UserId) -> Result<Option<User>, RepositoryError>;
    async fn find_by_email(&self, email: &str) -> Result<Option<User>, RepositoryError>;
    async fn save(&self, user: &User) -> Result<(), RepositoryError>;
    async fn delete(&self, id: UserId) -> Result<(), RepositoryError>;
}

pub struct PostgresUserRepository {
    pool: sqlx::PgPool,
}

#[async_trait]
impl UserRepository for PostgresUserRepository {
    async fn find_by_id(&self, id: UserId) -> Result<Option<User>, RepositoryError> {
        sqlx::query_as!(
            UserRow,
            "SELECT id, name, email FROM users WHERE id = $1",
            id.inner()
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(RepositoryError::Database)
        .map(|row| row.map(User::from))
    }
    // ... other methods
}

// In tests: mock implementation
pub struct InMemoryUserRepository {
    users: tokio::sync::Mutex<std::collections::HashMap<UserId, User>>,
}
```

---

## Pattern Selection Guide

| Need | Pattern |
|------|---------|
| Complex object construction with optional fields | Builder |
| Prevent mixing semantically different values of same type | Newtype |
| Enforce state machine at compile time | Typestate |
| Pluggable algorithms / interchangeable behaviors | Strategy |
| Publish-subscribe event handling | Observer (broadcast channel) |
| Data access abstraction for testability | Repository |
| Shared ownership across threads | `Arc<T>` |
| Interior mutability in single-threaded context | `RefCell<T>` / `Cell<T>` |
| Interior mutability across threads | `Mutex<T>` / `RwLock<T>` |
| Lazy initialization | `once_cell::sync::Lazy` / `std::sync::OnceLock` |

## Anti-patterns to Avoid

| Anti-pattern | Problem | Fix |
|-------------|---------|-----|
| God struct with everything | Hard to test, violates SRP | Split into focused structs with traits |
| `pub` everything | Leaks implementation details | Expose only what consumers need |
| `unwrap()` as error handling | Panics in production | Use `?` and typed errors |
| Deep inheritance via traits | Trait object hell | Prefer composition and enums |
| `dyn Trait` for closed set | Heap allocation, no exhaustive match | Use `enum` |
| Shared mutable global state | Hard to test, race conditions | Use `Arc<Mutex<T>>` or channels |
