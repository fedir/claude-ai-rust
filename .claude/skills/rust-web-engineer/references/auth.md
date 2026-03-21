# Authentication & Authorization Reference

## JWT Middleware for axum

```rust
use axum::{extract::FromRequestParts, http::request::Parts};
use axum_extra::{headers::{Authorization, authorization::Bearer}, TypedHeader};
use jsonwebtoken::{decode, DecodingKey, Validation};
use uuid::Uuid;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Claims {
    pub sub: Uuid,
    pub email: String,
    pub roles: Vec<String>,
    pub exp: usize,
    pub iat: usize,
}

#[derive(Debug, Clone)]
pub struct AuthUser {
    pub user_id: Uuid,
    pub email: String,
    pub roles: Vec<String>,
}

#[async_trait::async_trait]
impl<S> FromRequestParts<S> for AuthUser
where
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        // Extract Bearer token
        let TypedHeader(Authorization(bearer)) =
            TypedHeader::<Authorization<Bearer>>::from_request_parts(parts, state)
                .await
                .map_err(|_| AppError::Unauthorized)?;

        // Get secret from extensions (put there by state layer)
        let app_state = AppState::from_request_parts(parts, state)
            .await
            .map_err(|_| AppError::Internal(anyhow::anyhow!("no app state")))?;

        let claims = decode::<Claims>(
            bearer.token(),
            &DecodingKey::from_secret(app_state.config.jwt_secret.expose_secret().as_bytes()),
            &Validation::default(),
        )
        .map_err(|e| match e.kind() {
            jsonwebtoken::errors::ErrorKind::ExpiredSignature => AppError::TokenExpired,
            _ => AppError::Unauthorized,
        })?
        .claims;

        Ok(AuthUser {
            user_id: claims.sub,
            email: claims.email,
            roles: claims.roles,
        })
    }
}

// RBAC helper
pub struct RequireRole(pub &'static str);

#[async_trait::async_trait]
impl<S> FromRequestParts<S> for RequireRole
where
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let auth = AuthUser::from_request_parts(parts, state).await?;
        // stored via extension by AuthUser — or re-extract
        Ok(RequireRole("admin")) // simplified — see full impl
    }
}

// Usage in handlers:
pub async fn admin_dashboard(
    auth: AuthUser,
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, AppError> {
    if !auth.roles.contains(&"admin".to_string()) {
        return Err(AppError::Forbidden);
    }
    // ...
}
```

## Auth Handlers

```rust
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use argon2::password_hash::{rand_core::OsRng, SaltString};
use jsonwebtoken::{encode, EncodingKey, Header};

#[derive(serde::Deserialize, validator::Validate)]
pub struct LoginRequest {
    #[validate(email)]
    pub email: String,
    #[validate(length(min = 1))]
    pub password: String,
}

#[derive(serde::Serialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub token_type: String,
    pub expires_in: u64,
}

pub async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<Json<TokenResponse>, AppError> {
    req.validate()?;

    let user = db::users::find_by_email(&state.pool, &req.email)
        .await?
        .ok_or(AppError::Unauthorized)?;

    // Constant-time password verification
    let parsed_hash = PasswordHash::new(&user.password_hash)
        .map_err(|_| AppError::Internal(anyhow::anyhow!("invalid hash")))?;

    Argon2::default()
        .verify_password(req.password.as_bytes(), &parsed_hash)
        .map_err(|_| AppError::Unauthorized)?;

    let token = generate_jwt(&user, &state.config)?;

    Ok(Json(TokenResponse {
        access_token: token,
        token_type: "Bearer".into(),
        expires_in: 3600,
    }))
}

pub async fn register(
    State(state): State<AppState>,
    Json(req): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    req.validate()?;

    let salt = SaltString::generate(&mut OsRng);
    let password_hash = Argon2::default()
        .hash_password(req.password.as_bytes(), &salt)
        .map_err(|e| AppError::Internal(anyhow::anyhow!("hashing: {e}")))?
        .to_string();

    let user = db::users::create(&state.pool, &req.email, &req.name, &password_hash).await?;
    Ok((StatusCode::CREATED, Json(UserResponse::from(user))))
}

fn generate_jwt(user: &User, config: &Config) -> Result<String, AppError> {
    use secrecy::ExposeSecret;
    let now = chrono::Utc::now().timestamp() as usize;
    let claims = Claims {
        sub: user.id,
        email: user.email.clone(),
        roles: vec!["user".into()],
        iat: now,
        exp: now + 3600,
    };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(config.jwt_secret.expose_secret().as_bytes()),
    )
    .map_err(|e| AppError::Internal(anyhow::anyhow!("JWT encode: {e}")))
}
```

## API Key Authentication

```rust
pub struct ApiKeyAuth {
    pub client_id: String,
}

#[async_trait::async_trait]
impl<S> FromRequestParts<S> for ApiKeyAuth
where
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let app_state = AppState::from_request_parts(parts, state).await
            .map_err(|_| AppError::Unauthorized)?;

        let api_key = parts
            .headers
            .get("x-api-key")
            .and_then(|v| v.to_str().ok())
            .ok_or(AppError::Unauthorized)?;

        let client = db::api_keys::find_by_key(&app_state.pool, api_key)
            .await?
            .ok_or(AppError::Unauthorized)?;

        if !client.is_active {
            return Err(AppError::Unauthorized);
        }

        Ok(ApiKeyAuth { client_id: client.id })
    }
}
```

## Refresh Tokens

```rust
pub async fn refresh_token(
    State(state): State<AppState>,
    Json(req): Json<RefreshRequest>,
) -> Result<Json<TokenResponse>, AppError> {
    // Validate refresh token from DB (single-use)
    let session = db::sessions::find_by_refresh_token(&state.pool, &req.refresh_token)
        .await?
        .ok_or(AppError::Unauthorized)?;

    if session.expires_at < chrono::Utc::now() {
        return Err(AppError::TokenExpired);
    }

    // Rotate: delete old, create new
    let mut tx = state.pool.begin().await?;
    db::sessions::delete(&mut tx, session.id).await?;

    let user = db::users::find_by_id(&mut tx, session.user_id)
        .await?
        .ok_or(AppError::Unauthorized)?;

    let (access_token, refresh_token) = create_token_pair(&user, &state.config, &mut tx).await?;
    tx.commit().await?;

    Ok(Json(TokenResponse {
        access_token,
        token_type: "Bearer".into(),
        expires_in: 3600,
        // include refresh_token in response
    }))
}
```
