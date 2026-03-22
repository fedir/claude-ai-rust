# syntax=docker/dockerfile:1

# ─── Stage 1: Chef planner ───────────────────────────────────────────────────
FROM rust:1.88-alpine AS planner
RUN apk add --no-cache musl-dev
RUN cargo install cargo-chef --locked
WORKDIR /app
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

# ─── Stage 2: Dependency cacher ──────────────────────────────────────────────
FROM rust:1.88-alpine AS cacher
RUN apk add --no-cache musl-dev
RUN cargo install cargo-chef --locked
WORKDIR /app
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json

# ─── Stage 3: Builder ────────────────────────────────────────────────────────
FROM rust:1.88-alpine AS builder
RUN apk add --no-cache musl-dev
WORKDIR /app
COPY . .
COPY --from=cacher /app/target target
COPY --from=cacher /usr/local/cargo /usr/local/cargo
# Replace 'placeholder' with your actual binary name
RUN cargo build --release --bin placeholder \
    && strip target/release/placeholder

# ─── Stage 4: Final (distroless) ─────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /app/target/release/placeholder /app
COPY --from=builder /app/migrations /migrations

EXPOSE 8080

USER nonroot:nonroot

CMD ["/app"]
