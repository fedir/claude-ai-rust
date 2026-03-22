# gRPC Patterns Skill

tonic server/client patterns, protobuf setup, streaming RPCs, interceptors, health checks, and testing for Rust.

## When to Use
- Building gRPC services with tonic
- Designing protobuf schemas and service definitions
- Implementing streaming RPCs (server, client, bidirectional)
- Adding interceptors (auth, logging, metrics)
- Testing gRPC services

---

## Setup

```toml
[dependencies]
tonic = "0.12"
prost = "0.13"
prost-types = "0.13"
tokio = { version = "1", features = ["full"] }
tonic-health = "0.12"
tonic-reflection = "0.12"

[build-dependencies]
tonic-build = "0.12"
```

```rust
// build.rs
fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["proto/user.proto"], &["proto/"])?;
    Ok(())
}
```

---

## Proto Definition

```protobuf
// proto/user.proto
syntax = "proto3";

package user.v1;

service UserService {
  // Unary
  rpc GetUser(GetUserRequest) returns (GetUserResponse);
  rpc CreateUser(CreateUserRequest) returns (CreateUserResponse);

  // Server streaming
  rpc ListUsers(ListUsersRequest) returns (stream UserResponse);

  // Client streaming
  rpc ImportUsers(stream CreateUserRequest) returns (ImportUsersResponse);

  // Bidirectional streaming
  rpc SyncUsers(stream SyncRequest) returns (stream SyncResponse);
}

message GetUserRequest {
  string id = 1;
}

message GetUserResponse {
  User user = 1;
}

message CreateUserRequest {
  string email = 1;
  string name = 2;
}

message CreateUserResponse {
  User user = 1;
}

message User {
  string id = 1;
  string email = 2;
  string name = 3;
  string created_at = 4;
}

message ListUsersRequest {
  int32 page_size = 1;
  string page_token = 2;
}

message UserResponse {
  User user = 1;
}

message ImportUsersResponse {
  int32 imported_count = 1;
}

message SyncRequest {
  oneof action {
    User upsert = 1;
    string delete_id = 2;
  }
}

message SyncResponse {
  string id = 1;
  string status = 2;
}
```

---

## Server Implementation

```rust
use tonic::{Request, Response, Status};
use tokio_stream::wrappers::ReceiverStream;

// Generated code
pub mod user_v1 {
    tonic::include_proto!("user.v1");
}

use user_v1::user_service_server::{UserService, UserServiceServer};
use user_v1::*;

pub struct UserServiceImpl {
    pool: sqlx::PgPool,
}

impl UserServiceImpl {
    pub fn new(pool: sqlx::PgPool) -> Self {
        Self { pool }
    }
}

impl UserService for UserServiceImpl {
    // Unary RPC
    async fn get_user(
        &self,
        request: Request<GetUserRequest>,
    ) -> Result<Response<GetUserResponse>, Status> {
        let req = request.into_inner();

        let id: uuid::Uuid = req.id.parse()
            .map_err(|_| Status::invalid_argument("invalid UUID"))?;

        let user = db::users::find_by_id(&self.pool, id)
            .await
            .map_err(|e| {
                tracing::error!(error = %e, "Database error");
                Status::internal("internal error")
            })?
            .ok_or_else(|| Status::not_found("user not found"))?;

        Ok(Response::new(GetUserResponse {
            user: Some(user.into()),
        }))
    }

    // Server streaming RPC
    type ListUsersStream = ReceiverStream<Result<UserResponse, Status>>;

    async fn list_users(
        &self,
        request: Request<ListUsersRequest>,
    ) -> Result<Response<Self::ListUsersStream>, Status> {
        let req = request.into_inner();
        let pool = self.pool.clone();

        let (tx, rx) = tokio::sync::mpsc::channel(128);

        tokio::spawn(async move {
            let mut stream = sqlx::query_as!(
                db::UserRow,
                "SELECT * FROM users ORDER BY created_at LIMIT $1",
                i64::from(req.page_size.max(1).min(100))
            )
            .fetch(&pool);

            use futures::StreamExt;
            while let Some(row) = stream.next().await {
                let response = match row {
                    Ok(user) => Ok(UserResponse { user: Some(user.into()) }),
                    Err(e) => {
                        tracing::error!(error = %e, "Stream error");
                        Err(Status::internal("stream error"))
                    }
                };
                if tx.send(response).await.is_err() {
                    break; // Client disconnected
                }
            }
        });

        Ok(Response::new(ReceiverStream::new(rx)))
    }
}
```

---

## Server Startup

```rust
use tonic::transport::Server;
use tonic_health::server::health_reporter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().json().init();

    let pool = sqlx::PgPool::connect(&std::env::var("DATABASE_URL")?).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;

    let addr = "0.0.0.0:50051".parse()?;

    // Health check service
    let (mut health_reporter, health_service) = health_reporter();
    health_reporter.set_serving::<UserServiceServer<UserServiceImpl>>().await;

    // Reflection (for grpcurl / grpc-web tooling)
    let reflection = tonic_reflection::server::Builder::configure()
        .register_encoded_file_descriptor_set(user_v1::FILE_DESCRIPTOR_SET)
        .build_v1()?;

    let user_service = UserServiceImpl::new(pool);

    tracing::info!(%addr, "gRPC server listening");

    Server::builder()
        .add_service(health_service)
        .add_service(reflection)
        .add_service(UserServiceServer::new(user_service))
        .serve_with_shutdown(addr, shutdown_signal())
        .await?;

    Ok(())
}
```

---

## Interceptors (Auth, Logging)

```rust
use tonic::{service::interceptor, Request, Status};

// Auth interceptor
fn auth_interceptor(req: Request<()>) -> Result<Request<()>, Status> {
    let token = req.metadata()
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| Status::unauthenticated("missing auth token"))?;

    let token = token.strip_prefix("Bearer ")
        .ok_or_else(|| Status::unauthenticated("invalid auth scheme"))?;

    // Validate JWT
    let _claims = verify_jwt(token)
        .map_err(|_| Status::unauthenticated("invalid token"))?;

    Ok(req)
}

// Apply to service
Server::builder()
    .add_service(
        UserServiceServer::with_interceptor(user_service, auth_interceptor)
    )
    .serve(addr)
    .await?;

// Tower layer for logging (applies to all services)
use tower::ServiceBuilder;
use tower_http::trace::TraceLayer;

Server::builder()
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_grpc())
    )
    .add_service(UserServiceServer::new(user_service))
    .serve(addr)
    .await?;
```

---

## Client

```rust
use user_v1::user_service_client::UserServiceClient;

pub async fn create_client(addr: &str) -> Result<UserServiceClient<tonic::transport::Channel>, tonic::transport::Error> {
    UserServiceClient::connect(addr.to_string()).await
}

// Unary call
pub async fn get_user(client: &mut UserServiceClient<tonic::transport::Channel>, id: &str) -> Result<User, Status> {
    let response = client.get_user(GetUserRequest { id: id.to_string() }).await?;
    response.into_inner().user.ok_or_else(|| Status::internal("missing user"))
}

// Server streaming — consume
pub async fn list_all_users(client: &mut UserServiceClient<tonic::transport::Channel>) -> Result<Vec<User>, Status> {
    let response = client.list_users(ListUsersRequest { page_size: 100, page_token: String::new() }).await?;
    let mut stream = response.into_inner();

    let mut users = Vec::new();
    while let Some(item) = stream.message().await? {
        if let Some(user) = item.user {
            users.push(user);
        }
    }
    Ok(users)
}
```

---

## Error Mapping

```rust
// Map domain errors to gRPC Status
impl From<AppError> for Status {
    fn from(e: AppError) -> Self {
        match e {
            AppError::NotFound => Status::not_found("not found"),
            AppError::Validation(v) => Status::invalid_argument(v.to_string()),
            AppError::Unauthorized => Status::unauthenticated("unauthorized"),
            AppError::Forbidden => Status::permission_denied("forbidden"),
            AppError::Conflict(msg) => Status::already_exists(msg),
            AppError::Database(sqlx::Error::RowNotFound) => Status::not_found("not found"),
            AppError::Database(e) => {
                tracing::error!(error = %e, "Database error");
                Status::internal("internal error")
            }
            _ => {
                tracing::error!(error = %e, "Internal error");
                Status::internal("internal error")
            }
        }
    }
}
```

---

## Testing

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tonic::transport::Server;
    use tokio::net::TcpListener;

    async fn start_test_server(pool: sqlx::PgPool) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        let service = UserServiceImpl::new(pool);

        tokio::spawn(async move {
            Server::builder()
                .add_service(UserServiceServer::new(service))
                .serve_with_incoming(tokio_stream::wrappers::TcpListenerStream::new(listener))
                .await
                .unwrap();
        });

        format!("http://{addr}")
    }

    #[sqlx::test]
    async fn test_create_and_get_user(pool: sqlx::PgPool) {
        let addr = start_test_server(pool).await;
        let mut client = UserServiceClient::connect(addr).await.unwrap();

        // Create
        let response = client.create_user(CreateUserRequest {
            email: "alice@example.com".into(),
            name: "Alice".into(),
        }).await.unwrap();
        let created = response.into_inner().user.unwrap();
        assert_eq!(created.email, "alice@example.com");

        // Get
        let response = client.get_user(GetUserRequest { id: created.id.clone() }).await.unwrap();
        let fetched = response.into_inner().user.unwrap();
        assert_eq!(fetched.id, created.id);
    }

    #[sqlx::test]
    async fn test_get_user_not_found(pool: sqlx::PgPool) {
        let addr = start_test_server(pool).await;
        let mut client = UserServiceClient::connect(addr).await.unwrap();

        let result = client.get_user(GetUserRequest {
            id: uuid::Uuid::new_v4().to_string(),
        }).await;

        assert_eq!(result.unwrap_err().code(), tonic::Code::NotFound);
    }
}
```

---

## Proto Best Practices

| Rule | Rationale |
|------|-----------|
| Package with version (`user.v1`) | Enables backward-compatible evolution |
| Wrapper messages for all RPCs | Allows adding fields without breaking changes |
| `string` for UUIDs/timestamps | Proto has no native UUID; use RFC 3339 for timestamps |
| `oneof` for polymorphism | Type-safe union instead of empty fields |
| `page_size` + `page_token` | Standard pagination per AIP-158 |
| Field numbers never reused | Protobuf wire format depends on numbers |
| `option` for optional fields | Explicit presence tracking in proto3 |

## When gRPC vs REST

| Choose gRPC | Choose REST |
|-------------|-------------|
| Service-to-service | Public API / browser clients |
| High throughput, low latency | Human-debuggable (curl, browser) |
| Streaming needed | Simple CRUD |
| Strong schema required | Loose coupling preferred |
| Internal microservices | Third-party integrations |

## Combined axum + tonic (same port)

```rust
// Serve both HTTP and gRPC on the same port using axum's routing
use axum::Router;

let grpc_service = tonic::transport::Server::builder()
    .add_service(UserServiceServer::new(user_service))
    .into_router();

let app = Router::new()
    .nest("/api/v1", rest_routes())
    .merge(grpc_service)      // gRPC on same port
    .with_state(state);

let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
axum::serve(listener, app).await?;
```
