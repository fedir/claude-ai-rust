# axum Web Reference

## Router with Full Middleware Stack

```rust
use axum::{Router, routing::{get, post, put, delete}};
use std::time::Duration;
use tower::ServiceBuilder;
use tower_http::{
    cors::CorsLayer,
    trace::TraceLayer,
    compression::CompressionLayer,
    timeout::TimeoutLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
};
use axum::http::HeaderName;

static X_REQUEST_ID: HeaderName = HeaderName::from_static("x-request-id");

pub fn create_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(handlers::health::health))
        .route("/ready", get(handlers::health::ready))
        .nest("/api/v1", v1_router())
        .layer(
            ServiceBuilder::new()
                .layer(SetRequestIdLayer::new(X_REQUEST_ID.clone(), MakeRequestUuid))
                .layer(PropagateRequestIdLayer::new(X_REQUEST_ID.clone()))
                .layer(TraceLayer::new_for_http())
                .layer(TimeoutLayer::new(Duration::from_secs(30)))
                .layer(CompressionLayer::new())
                .layer(CorsLayer::permissive()), // tighten in production
        )
        .with_state(state)
}

fn v1_router() -> Router<AppState> {
    Router::new()
        .nest("/users", user_routes())
        .nest("/orders", order_routes())
}

fn user_routes() -> Router<AppState> {
    Router::new()
        .route("/", get(handlers::users::list).post(handlers::users::create))
        .route("/:id",
            get(handlers::users::get_by_id)
                .put(handlers::users::update)
                .delete(handlers::users::delete)
        )
}
```

## Handlers with All Extractor Types

```rust
use axum::{
    extract::{Path, Query, State, Json},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use serde::Deserialize;
use uuid::Uuid;

// Query parameters
#[derive(Debug, Deserialize)]
pub struct PaginationQuery {
    #[serde(default = "default_page")]
    pub page: i64,
    #[serde(default = "default_per_page")]
    pub per_page: i64,
    pub q: Option<String>,
    pub status: Option<UserStatus>,
}
fn default_page() -> i64 { 1 }
fn default_per_page() -> i64 { 20 }

// List handler
pub async fn list(
    State(state): State<AppState>,
    Query(query): Query<PaginationQuery>,
) -> Result<Json<PageResponse<UserResponse>>, AppError> {
    let page = services::users::list(&state.pool, &query).await?;
    Ok(Json(page.map(UserResponse::from)))
}

// Get by ID
pub async fn get_by_id(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<Json<UserResponse>, AppError> {
    let user = services::users::find_by_id(&state.pool, id)
        .await?
        .ok_or(AppError::NotFound)?;
    Ok(Json(UserResponse::from(user)))
}

// Create — returns 201
pub async fn create(
    State(state): State<AppState>,
    Json(req): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    req.validate()?;
    let user = services::users::create(&state.pool, req).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(user))))
}

// Delete — returns 204
pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    auth: AuthUser,
) -> Result<StatusCode, AppError> {
    services::users::delete(&state.pool, id, auth.user_id).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

## Request / Response DTOs

```rust
use serde::{Deserialize, Serialize};
use validator::Validate;
use chrono::{DateTime, Utc};
use uuid::Uuid;

#[derive(Debug, Deserialize, Validate)]
pub struct CreateUserRequest {
    #[validate(email)]
    pub email: String,
    #[validate(length(min = 1, max = 100))]
    pub name: String,
    #[validate(length(min = 8))]
    pub password: String,
}

#[derive(Debug, Deserialize, Validate)]
pub struct UpdateUserRequest {
    #[validate(length(min = 1, max = 100))]
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UserResponse {
    pub id: Uuid,
    pub email: String,
    pub name: String,
    pub status: UserStatus,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct PageResponse<T> {
    pub items: Vec<T>,
    pub total: i64,
    pub page: i64,
    pub per_page: i64,
    pub total_pages: i64,
}

impl<T> PageResponse<T> {
    pub fn map<U>(self, f: impl Fn(T) -> U) -> PageResponse<U> {
        PageResponse {
            items: self.items.into_iter().map(f).collect(),
            total: self.total,
            page: self.page,
            per_page: self.per_page,
            total_pages: self.total_pages,
        }
    }
}
```

## Custom Extractor with Validation

```rust
use axum::{extract::FromRequest, http::Request, body::Body};
use axum::response::Response;
use validator::Validate;

pub struct ValidatedJson<T>(pub T);

#[async_trait::async_trait]
impl<T, S> FromRequest<S> for ValidatedJson<T>
where
    T: serde::de::DeserializeOwned + Validate,
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request(req: Request<Body>, state: &S) -> Result<Self, Self::Rejection> {
        let Json(value) = Json::<T>::from_request(req, state)
            .await
            .map_err(|e| AppError::from(anyhow::anyhow!("JSON parse error: {e}")))?;
        value.validate()?;
        Ok(ValidatedJson(value))
    }
}

// Usage:
pub async fn create(
    State(state): State<AppState>,
    ValidatedJson(req): ValidatedJson<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    // req is already validated
    let user = services::users::create(&state.pool, req).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(user))))
}
```

## Global 404 / Fallback

```rust
Router::new()
    .route(/* ... */)
    .fallback(|| async {
        (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "NOT_FOUND", "message": "endpoint not found" })),
        )
    })
```
