---
name: api-contract-review
description: Review REST API contracts for HTTP semantics, versioning, backward compatibility, and response consistency. Use when user asks "review API", "check endpoints", "REST review", or before releasing API changes. Includes axum routing examples.
---

# API Contract Review Skill

Audit REST API design for correctness, consistency, and compatibility. Examples use Rust/axum.

## When to Use
- User asks "review this API" / "check REST endpoints"
- Before releasing API changes
- Reviewing PR with handler/router changes
- Checking backward compatibility

---

## Quick Reference: Common Issues

| Issue | Symptom | Impact |
|-------|---------|--------|
| Wrong HTTP verb | POST for idempotent operation | Confusion, caching issues |
| Missing versioning | `/users` instead of `/v1/users` | Breaking changes affect all clients |
| Model leak | DB row struct in response | Exposes internals (password hash, etc.) |
| 200 with error | `{"status": 200, "error": "..."}` | Breaks error handling |
| Inconsistent naming | `/getUsers` vs `/users` | Hard to learn API |

---

## HTTP Verb Semantics

### Verb Selection Guide

| Verb | Use For | Idempotent | Safe | Request Body |
|------|---------|------------|------|--------------|
| GET | Retrieve resource | Yes | Yes | No |
| POST | Create new resource | No | No | Yes |
| PUT | Replace entire resource | Yes | No | Yes |
| PATCH | Partial update | No* | No | Yes |
| DELETE | Remove resource | Yes | No | Optional |

*PATCH can be idempotent depending on implementation

### Common Mistakes (axum)

```rust
// ❌ POST for retrieval
Router::new().route("/users/search", post(search_users));

// ✅ GET with query params (or POST only if criteria is very complex)
Router::new().route("/users", get(search_users));

pub async fn search_users(
    Query(params): Query<SearchParams>,
) -> Result<Json<Vec<UserResponse>>, AppError> { ... }

// ❌ GET for state change
Router::new().route("/users/:id/activate", get(activate_user));

// ✅ POST or PATCH for state change
Router::new().route("/users/:id/activate", post(activate_user));

// ❌ POST for idempotent update
Router::new().route("/users/:id", post(update_user));

// ✅ PUT for full replacement, PATCH for partial
Router::new()
    .route("/users/:id", put(replace_user).patch(update_user));
```

---

## API Versioning

### Strategies

| Strategy | Example | Pros | Cons |
|----------|---------|------|------|
| URL path | `/v1/users` | Clear, easy routing | URL changes |
| Header | `Accept: application/vnd.api.v1+json` | Clean URLs | Hidden, harder to test |
| Query param | `/users?version=1` | Easy to add | Easy to forget |

### Recommended: URL Path (axum)

```rust
// ✅ Versioned route nesting
pub fn create_router(state: AppState) -> Router {
    Router::new()
        .nest("/api/v1", v1_routes())
        .nest("/api/v2", v2_routes())
        .with_state(state)
}

fn v1_routes() -> Router<AppState> {
    Router::new()
        .nest("/users", user_routes_v1())
        .nest("/orders", order_routes_v1())
}

fn v2_routes() -> Router<AppState> {
    Router::new()
        .nest("/users", user_routes_v2()) // Updated response format
}

// ❌ No versioning
Router::new()
    .route("/api/users", get(list_users)) // Breaking changes affect everyone
```

### Version Checklist
- [ ] All public APIs have version in path
- [ ] Internal APIs documented as internal (or versioned too)
- [ ] Deprecation strategy defined for old versions

---

## Request/Response Design

### DTO vs DB Model

```rust
// ❌ DB model in response (leaks internals)
pub async fn get_user(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<User>, AppError> {
    let user = db::users::find_by_id(&state.pool, id).await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(user)) // Exposes: password_hash, internal fields
}

// ✅ DTO response
pub async fn get_user(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<UserResponse>, AppError> {
    let user = db::users::find_by_id(&state.pool, id).await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(UserResponse::from(user))) // Only public fields
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserResponse {
    pub id: Uuid,
    pub email: String,
    pub name: String,
    pub created_at: DateTime<Utc>,
    // No password_hash, no internal status codes
}
```

### Response Consistency

```rust
// ❌ Inconsistent: array vs object vs primitive
pub async fn list() -> Json<Vec<User>> { ... }     // array
pub async fn get() -> Json<User> { ... }             // object
pub async fn count() -> Json<i64> { ... }            // primitive

// ✅ Consistent structure
pub async fn list() -> Json<PageResponse<UserResponse>> { ... }
pub async fn get() -> Json<UserResponse> { ... }
pub async fn count() -> Json<CountResponse> { ... }  // { "count": 42 }
```

### Pagination

```rust
// ❌ No pagination on collections
pub async fn list_users(
    State(state): State<AppState>,
) -> Result<Json<Vec<UserResponse>>, AppError> {
    let users = db::users::find_all(&state.pool).await?; // Could be millions
    Ok(Json(users))
}

// ✅ Paginated
pub async fn list_users(
    State(state): State<AppState>,
    Query(params): Query<PaginationQuery>,
) -> Result<Json<PageResponse<UserResponse>>, AppError> {
    let page = db::users::list(&state.pool, params.page, params.per_page).await?;
    Ok(Json(page.map(UserResponse::from)))
}
```

---

## HTTP Status Codes

### Success Codes

| Code | When to Use | Response Body |
|------|-------------|---------------|
| 200 OK | Successful GET, PUT, PATCH | Resource or result |
| 201 Created | Successful POST (created) | Created resource + Location header |
| 204 No Content | Successful DELETE, or PUT with no body | Empty |

### Error Codes

| Code | When to Use | Common Mistake |
|------|-------------|----------------|
| 400 Bad Request | Malformed request syntax | Using for "not found" |
| 401 Unauthorized | Not authenticated | Confusing with 403 |
| 403 Forbidden | Authenticated but not allowed | Using 401 instead |
| 404 Not Found | Resource doesn't exist | Using 400 |
| 409 Conflict | Duplicate, concurrent modification | Using 400 |
| 422 Unprocessable | Semantic error (valid syntax, invalid meaning) | Using 400 |
| 500 Internal Error | Unexpected server error | Exposing stack traces |

### Anti-Pattern: 200 with Error Body

```rust
// ❌ NEVER DO THIS
pub async fn get_user(
    Path(id): Path<Uuid>,
) -> Json<serde_json::Value> {
    match find_user(id).await {
        Ok(user) => Json(json!({ "status": "success", "data": user })),
        Err(_) => Json(json!({ "status": "error", "message": "not found" })), // Still 200!
    }
}

// ✅ Use proper status codes via AppError → IntoResponse
pub async fn get_user(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<UserResponse>, AppError> {
    let user = db::users::find_by_id(&state.pool, id).await?
        .ok_or(AppError::NotFound)?;  // Returns 404
    Ok(Json(UserResponse::from(user)))  // Returns 200
}
```

---

## Error Response Format

### Consistent Error Structure

> See canonical `AppError` in `rust-architect/references/rust-setup.md`.

```json
{
  "error": "USER_NOT_FOUND",
  "message": "User with ID 550e8400-... not found"
}
```

For validation errors, include field details:
```json
{
  "error": "VALIDATION_ERROR",
  "message": "Validation failed",
  "fields": {
    "email": "invalid email format",
    "password": "must be at least 8 characters"
  }
}
```

### Security: Don't Expose Internals

```rust
// ❌ Exposes internal error details
AppError::Database(e) => {
    (StatusCode::INTERNAL_SERVER_ERROR, format!("DB error: {e}"))
}

// ✅ Generic message, log details server-side
AppError::Database(e) => {
    tracing::error!(error = %e, "Database error");
    (StatusCode::INTERNAL_SERVER_ERROR, "internal server error".to_string())
}
```

---

## Backward Compatibility

### Breaking Changes (Avoid in Same Version)

| Change | Breaking? | Migration |
|--------|-----------|-----------|
| Remove endpoint | Yes | Deprecate first, remove in next version |
| Remove field from response | Yes | Keep field, return null/default |
| Add required field to request | Yes | Make optional with default |
| Change field type | Yes | Add new field, deprecate old |
| Rename field | Yes | Support both temporarily |
| Change URL path | Yes | Redirect old to new |

### Non-Breaking Changes (Safe)

- Add optional field to request
- Add field to response
- Add new endpoint
- Add new optional query parameter

### Deprecation Pattern (axum)

```rust
fn user_routes() -> Router<AppState> {
    Router::new()
        // New canonical endpoint
        .route("/", get(list_users))
        // Deprecated endpoint — delegates to new handler, logs warning
        .route("/by-email", get(get_by_email_deprecated))
}

pub async fn get_by_email_deprecated(
    State(state): State<AppState>,
    Query(params): Query<EmailQuery>,
) -> Result<Json<UserResponse>, AppError> {
    tracing::warn!(endpoint = "/users/by-email", "Deprecated endpoint called");
    get_by_email(State(state), Query(params)).await
}
```

---

## API Review Checklist

### 1. HTTP Semantics
- [ ] GET for retrieval only (no side effects)
- [ ] POST for creation (returns 201 + Location)
- [ ] PUT for full replacement (idempotent)
- [ ] PATCH for partial updates
- [ ] DELETE for removal (idempotent, returns 204)

### 2. URL Design
- [ ] Versioned (`/v1/`, `/v2/`)
- [ ] Nouns, not verbs (`/users`, not `/getUsers`)
- [ ] Plural for collections (`/users`, not `/user`)
- [ ] Hierarchical for relationships (`/users/{id}/orders`)
- [ ] Consistent naming (kebab-case preferred)

### 3. Request Handling
- [ ] Validation with `validator` or `garde` (at extractor level)
- [ ] Clear error messages for validation failures
- [ ] Request DTOs (not DB models)
- [ ] Reasonable size limits (`tower_http::limit::RequestBodyLimitLayer`)

### 4. Response Design
- [ ] Response DTOs (not DB row structs)
- [ ] Consistent structure across endpoints
- [ ] Pagination for collections
- [ ] Proper status codes (not 200 for errors)
- [ ] `#[serde(rename_all = "camelCase")]` for JSON API convention

### 5. Error Handling
- [ ] Consistent error JSON format
- [ ] Machine-readable error codes
- [ ] Human-readable messages
- [ ] No stack traces or internal details exposed
- [ ] Proper 4xx vs 5xx distinction

### 6. Compatibility
- [ ] No breaking changes in current version
- [ ] Deprecated endpoints documented and logged
- [ ] Migration path for breaking changes

---

## Quick Scan Commands

```bash
# Find potential DB model leaks in handlers
grep -rn "Json<.*Row\|Json<.*Entity\|Json<.*Model" src/handlers/

# Find handlers returning raw sqlx types
grep -rn "sqlx::FromRow" src/handlers/

# Find unversioned API routes
grep -rn 'route.*"/api/' src/ | grep -v '/v[0-9]'

# Check for unwrap() in handlers (panics = 500 without proper error)
grep -rn 'unwrap()' src/handlers/
```
