# Rust Security Patterns Reference

## Password Hashing with argon2

```toml
[dependencies]
argon2 = "0.5"
rand_core = { version = "0.6", features = ["std"] }
```

```rust
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use argon2::password_hash::{rand_core::OsRng, SaltString};

pub fn hash_password(password: &str) -> Result<String, argon2::password_hash::Error> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let hash = argon2.hash_password(password.as_bytes(), &salt)?;
    Ok(hash.to_string())
}

pub fn verify_password(password: &str, hash: &str) -> Result<bool, argon2::password_hash::Error> {
    let parsed_hash = PasswordHash::new(hash)?;
    Ok(Argon2::default().verify_password(password.as_bytes(), &parsed_hash).is_ok())
}
```

## JWT with jsonwebtoken

```toml
[dependencies]
jsonwebtoken = "9"
```

```rust
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize)]
pub struct Claims {
    pub sub: Uuid,         // user ID
    pub email: String,
    pub roles: Vec<String>,
    pub exp: usize,        // expiration (unix timestamp)
    pub iat: usize,        // issued at
}

pub fn generate_token(user: &User, secret: &[u8]) -> Result<String, jsonwebtoken::errors::Error> {
    let now = chrono::Utc::now().timestamp() as usize;
    let claims = Claims {
        sub: user.id,
        email: user.email.clone(),
        roles: user.roles.clone(),
        iat: now,
        exp: now + 3600, // 1 hour
    };
    encode(&Header::default(), &claims, &EncodingKey::from_secret(secret))
}

pub fn verify_token(token: &str, secret: &[u8]) -> Result<Claims, jsonwebtoken::errors::Error> {
    let token_data = decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret),
        &Validation::default(),
    )?;
    Ok(token_data.claims)
}
```

## TLS with rustls

```toml
[dependencies]
axum-server = { version = "0.7", features = ["tls-rustls"] }
rustls = "0.23"
```

```rust
use axum_server::tls_rustls::RustlsConfig;

let config = RustlsConfig::from_pem_file("cert.pem", "key.pem").await?;

axum_server::bind_rustls(addr, config)
    .serve(app.into_make_service())
    .await?;
```

## Input Validation

```rust
use validator::Validate;

#[derive(Debug, Deserialize, Validate)]
pub struct CreateUserRequest {
    #[validate(email(message = "invalid email format"))]
    pub email: String,

    #[validate(length(min = 1, max = 100, message = "name must be 1-100 characters"))]
    pub name: String,

    #[validate(length(min = 8, message = "password must be at least 8 characters"))]
    pub password: String,
}

// Custom validator
#[derive(Debug, Deserialize, Validate)]
pub struct UpdatePriceRequest {
    #[validate(range(min = 0.01, max = 999999.99))]
    pub price: f64,

    #[validate(custom(function = "validate_currency_code"))]
    pub currency: String,
}

fn validate_currency_code(code: &str) -> Result<(), validator::ValidationError> {
    if ["USD", "EUR", "GBP"].contains(&code) {
        Ok(())
    } else {
        Err(validator::ValidationError::new("invalid_currency"))
    }
}
```

## Clearing Sensitive Data from Memory

```toml
[dependencies]
zeroize = { version = "1", features = ["derive"] }
secrecy = "0.10"
```

```rust
use zeroize::Zeroize;
use secrecy::{ExposeSecret, SecretString};

// Automatically zeroes memory on drop
#[derive(Zeroize)]
#[zeroize(drop)]
struct SensitiveData {
    password: String,
    secret_key: Vec<u8>,
}

// Use SecretString for passwords/tokens
pub struct AuthConfig {
    pub jwt_secret: SecretString,
}

impl AuthConfig {
    pub fn from_env() -> Result<Self, Error> {
        Ok(Self {
            jwt_secret: SecretString::new(
                std::env::var("JWT_SECRET")?.into()
            ),
        })
    }
}

// Access secret
fn sign_token(config: &AuthConfig) -> String {
    let secret = config.jwt_secret.expose_secret();
    // use secret here
    sign(secret)
}
```

## Rate Limiting

```toml
[dependencies]
tower_governor = "0.4"
```

```rust
use tower_governor::{governor::GovernorConfigBuilder, GovernorLayer};

let governor_config = GovernorConfigBuilder::default()
    .per_second(10)
    .burst_size(30)
    .use_headers()
    .finish()
    .unwrap();

let app = Router::new()
    .route("/api/login", post(login))
    .layer(GovernorLayer { config: Arc::new(governor_config) });
```

## Supply Chain Security

```bash
# Check for known CVEs in dependencies
cargo install cargo-audit
cargo audit

# Enforce license and dependency policies
cargo install cargo-deny
cargo deny check

# Find unused dependencies
cargo install cargo-machete
cargo machete

# Vet dependency supply chain
cargo install cargo-vet
cargo vet
```

```toml
# deny.toml
[licenses]
allow = ["MIT", "Apache-2.0", "Apache-2.0 WITH LLVM-exception", "BSD-2-Clause", "BSD-3-Clause", "ISC"]
deny = ["GPL-3.0"]

[bans]
multiple-versions = "warn"
deny = [
    { name = "openssl", reason = "use rustls instead" },
]

[advisories]
db-path = "~/.cargo/advisory-db"
db-urls = ["https://github.com/rustsec/advisory-db"]
vulnerability = "deny"
unmaintained = "warn"
```

## CORS Configuration

```rust
use tower_http::cors::{AllowHeaders, AllowMethods, AllowOrigin, CorsLayer};
use axum::http::{HeaderValue, Method};

fn cors_layer(allowed_origins: &[&str]) -> CorsLayer {
    let origins: Vec<HeaderValue> = allowed_origins
        .iter()
        .filter_map(|o| o.parse().ok())
        .collect();

    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST, Method::PUT, Method::DELETE])
        .allow_headers(AllowHeaders::mirror_request())
        .allow_credentials(true)
        .max_age(Duration::from_secs(3600))
}
```

## Security Headers

```rust
use tower_http::set_header::SetResponseHeaderLayer;
use axum::http::{header, HeaderValue};

fn security_headers() -> impl Layer<...> {
    tower::ServiceBuilder::new()
        .layer(SetResponseHeaderLayer::overriding(
            header::X_CONTENT_TYPE_OPTIONS,
            HeaderValue::from_static("nosniff"),
        ))
        .layer(SetResponseHeaderLayer::overriding(
            header::X_FRAME_OPTIONS,
            HeaderValue::from_static("DENY"),
        ))
        .layer(SetResponseHeaderLayer::if_not_present(
            header::STRICT_TRANSPORT_SECURITY,
            HeaderValue::from_static("max-age=63072000; includeSubDomains"),
        ))
}
```
