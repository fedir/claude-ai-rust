---
name: clean-code
description: Clean Code principles (DRY, KISS, YAGNI), naming conventions, function design, and refactoring for Rust. Use when user says "clean this code", "refactor", "improve readability", or when reviewing code quality.
---

# Clean Code Skill (Rust)

Write readable, maintainable Rust code following Clean Code principles and idiomatic patterns.

## When to Use
- User says "clean this code" / "refactor" / "improve readability"
- Code review focusing on maintainability
- Reducing complexity or improving naming

---

## Core Principles

| Principle | Meaning | Violation Sign |
|-----------|---------|----------------|
| **DRY** | Don't Repeat Yourself | Copy-pasted code blocks |
| **KISS** | Keep It Simple, Stupid | Over-engineered solutions |
| **YAGNI** | You Aren't Gonna Need It | Features "just in case" |

---

## DRY - Don't Repeat Yourself

```rust
// ❌ BAD: Same validation logic repeated
pub async fn create_user(email: &str) -> Result<User, Error> {
    if email.is_empty() || !email.contains('@') {
        return Err(Error::InvalidEmail);
    }
    // ...
}

pub async fn update_user(id: Uuid, email: &str) -> Result<User, Error> {
    if email.is_empty() || !email.contains('@') {  // Duplicate!
        return Err(Error::InvalidEmail);
    }
    // ...
}

// ✅ GOOD: Extract validation into single place
fn validate_email(email: &str) -> Result<(), Error> {
    if email.is_empty() || !email.contains('@') {
        return Err(Error::InvalidEmail);
    }
    Ok(())
}

pub async fn create_user(email: &str) -> Result<User, Error> {
    validate_email(email)?;
    // ...
}

pub async fn update_user(id: Uuid, email: &str) -> Result<User, Error> {
    validate_email(email)?;
    // ...
}

// ✅ EVEN BETTER: Use validator crate with derive
use validator::Validate;

#[derive(Deserialize, Validate)]
pub struct CreateUserRequest {
    #[validate(email)]
    pub email: String,
    #[validate(length(min = 1, max = 100))]
    pub name: String,
}
```

---

## KISS - Keep It Simple

```rust
// ❌ BAD: Over-engineered status check
fn is_user_active(status: &str) -> bool {
    let status_codes = std::collections::HashMap::from([
        ("active", true),
        ("inactive", false),
        ("suspended", false),
    ]);
    *status_codes.get(status).unwrap_or(&false)
}

// ✅ GOOD: Simple and direct
fn is_user_active(status: &str) -> bool {
    status == "active"
}

// ✅ BEST: Use a proper enum
#[derive(PartialEq)]
pub enum UserStatus { Active, Inactive, Suspended }

impl UserStatus {
    pub fn is_active(&self) -> bool {
        *self == Self::Active
    }
}
```

---

## YAGNI - You Aren't Gonna Need It

```rust
// ❌ BAD: Generic infrastructure for a simple feature
pub trait DataProcessor<T, O, E> { ... }
pub struct DataPipeline<T, O, E, P: DataProcessor<T, O, E>> { ... }
// Used only once, for one fixed type

// ✅ GOOD: Start simple, generalize when needed
pub fn process_users(users: Vec<User>) -> Vec<ProcessedUser> {
    users.into_iter().map(process_user).collect()
}
```

---

## Naming Conventions

| What | Convention | Examples |
|------|-----------|---------|
| Types/traits/enums | `PascalCase` | `UserRepository`, `AppError` |
| Functions/methods/variables | `snake_case` | `find_by_id`, `user_count` |
| Constants | `SCREAMING_SNAKE_CASE` | `MAX_RETRIES`, `DEFAULT_PORT` |
| Lifetimes | Single lowercase letter | `'a`, `'static` |
| Booleans | `is_`, `has_`, `can_`, `should_` | `is_active`, `has_permission` |
| Async functions | Same as sync — no `async_` prefix | `create_user` not `async_create_user` |
| Trait methods | Verb or adjective | `validate()`, `is_valid()`, `into_response()` |

```rust
// ❌ BAD: Unclear names
fn proc(d: &[u8]) -> Result<Vec<u8>, E> { ... }
let x = get_data(42).await?;
let flag = true;

// ✅ GOOD: Clear, intention-revealing names
fn compress(data: &[u8]) -> Result<Vec<u8>, CompressionError> { ... }
let user = find_user_by_id(user_id).await?;
let is_admin = true;
```

---

## Function Design

**Rule: A function should do one thing.**

```rust
// ❌ BAD: Function does too much
pub async fn register_user(email: &str, password: &str) -> Result<User, Error> {
    // 1. Validate email format
    if !email.contains('@') { return Err(Error::InvalidEmail); }
    // 2. Check email not taken
    let existing = db::find_by_email(email).await?;
    if existing.is_some() { return Err(Error::EmailTaken); }
    // 3. Hash password
    let hash = bcrypt::hash(password, 12)?;
    // 4. Save user
    let user = db::create_user(email, &hash).await?;
    // 5. Send welcome email
    email_service::send_welcome(email).await?;
    // 6. Create audit log
    audit::log_registration(user.id).await?;
    Ok(user)
}

// ✅ GOOD: Each function has single responsibility
pub async fn register_user(
    email: &str,
    password: &str,
    deps: &Deps,
) -> Result<User, RegistrationError> {
    deps.validator.validate_email(email)?;
    deps.user_repo.ensure_email_available(email).await?;
    let password_hash = deps.hasher.hash(password)?;
    let user = deps.user_repo.create(email, &password_hash).await?;
    deps.mailer.send_welcome(&user).await?;
    deps.audit.log_registration(user.id).await?;
    Ok(user)
}
```

---

## Guard Clauses (Early Returns)

```rust
// ❌ BAD: Arrow code — deeply nested
pub fn process_order(order: &Order) -> Result<(), Error> {
    if order.is_valid() {
        if order.has_items() {
            if order.items.iter().all(|i| i.in_stock()) {
                // actual logic buried here
                charge_payment(order)?;
                Ok(())
            } else {
                Err(Error::OutOfStock)
            }
        } else {
            Err(Error::EmptyOrder)
        }
    } else {
        Err(Error::InvalidOrder)
    }
}

// ✅ GOOD: Guard clauses flatten the logic
pub fn process_order(order: &Order) -> Result<(), Error> {
    if !order.is_valid() { return Err(Error::InvalidOrder); }
    if !order.has_items() { return Err(Error::EmptyOrder); }
    if !order.items.iter().all(|i| i.in_stock()) { return Err(Error::OutOfStock); }

    charge_payment(order)?;
    Ok(())
}
```

---

## Error Handling Clarity

```rust
// ❌ BAD: Cryptic error types
fn load_config() -> Result<Config, Box<dyn std::error::Error>> { ... }

// ✅ GOOD: Domain-specific error types
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("missing required env var: {var}")]
    MissingEnvVar { var: &'static str },
    #[error("invalid value for {var}: {reason}")]
    InvalidValue { var: &'static str, reason: String },
    #[error("IO error reading config file: {0}")]
    Io(#[from] std::io::Error),
}

fn load_config() -> Result<Config, ConfigError> { ... }
```

---

## Idiomatic Rust Patterns

```rust
// ❌ Use if let instead of match for single variant
match result {
    Ok(v) => process(v),
    Err(_) => {},
}
// ✅
if let Ok(v) = result { process(v); }

// ❌ Manual option checking
if user.email.is_some() {
    let email = user.email.unwrap();
    send_email(email);
}
// ✅
if let Some(email) = &user.email {
    send_email(email);
}
// or
user.email.as_ref().map(|e| send_email(e));

// ❌ Collect then iterate
let names: Vec<String> = users.iter().map(|u| u.name.clone()).collect();
for name in &names { println!("{}", name); }
// ✅ Lazy iterator
users.iter().map(|u| &u.name).for_each(|name| println!("{}", name));

// ❌ Manual default
let timeout = if config.timeout > 0 { config.timeout } else { 30 };
// ✅
let timeout = if config.timeout > 0 { config.timeout } else { DEFAULT_TIMEOUT };
// or with Option
let timeout = config.timeout.filter(|&t| t > 0).unwrap_or(DEFAULT_TIMEOUT);
```

---

## Code Smells Quick Reference

| Smell | Indicator | Fix |
|-------|-----------|-----|
| Long function | > 20 lines | Extract helper functions |
| Too many parameters | > 3 | Use a struct or builder |
| Deep nesting | > 3 levels | Guard clauses, extract functions |
| Duplicate code | Copy-paste | Extract function or macro |
| `unwrap()` everywhere | Lazy error handling | Use `?` and proper error types |
| Magic numbers | `if count > 100` | `const MAX_ITEMS: u32 = 100` |
| Boolean parameters | `create_user(true, false)` | Use enums: `Role::Admin` |
| Dead code | `#[allow(dead_code)]` | Remove it |

---

## Refactoring Checklist

Before submitting code, ask:
- [ ] Can I understand what this does without comments?
- [ ] Are all names clear and intention-revealing?
- [ ] Does each function do one thing?
- [ ] Are there any `unwrap()` / `expect()` that could be proper errors?
- [ ] Is there duplicated logic that could be extracted?
- [ ] Does `cargo clippy` produce any warnings?
- [ ] Would a new team member understand this in 5 minutes?
