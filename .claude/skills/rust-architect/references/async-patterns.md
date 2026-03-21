# Async Rust Patterns Reference

## tokio Runtime Setup

```rust
// Basic (most services)
#[tokio::main]
async fn main() -> anyhow::Result<()> { ... }

// Custom configuration
#[tokio::main(flavor = "multi_thread", worker_threads = 4)]
async fn main() -> anyhow::Result<()> { ... }

// Production: set via env
// TOKIO_WORKER_THREADS=8

// For tests
#[tokio::test(flavor = "multi_thread")]
async fn test_concurrent_requests() { ... }
```

---

## Channels

### mpsc — Multiple Producers, Single Consumer
```rust
use tokio::sync::mpsc;

let (tx, mut rx) = mpsc::channel::<Message>(100); // buffer size 100

// Producer (clone sender)
let tx2 = tx.clone();
tokio::spawn(async move {
    tx2.send(Message::new("hello")).await.expect("receiver dropped");
});

// Consumer
while let Some(msg) = rx.recv().await {
    process(msg).await;
}
```

### broadcast — Single Producer, Multiple Consumers
```rust
use tokio::sync::broadcast;

let (tx, _) = broadcast::channel::<Event>(256);

let mut rx1 = tx.subscribe();
let mut rx2 = tx.subscribe();

tx.send(Event::Started)?;

// Each receiver gets every message
tokio::spawn(async move {
    while let Ok(event) = rx1.recv().await {
        handle_event(event).await;
    }
});
```

### oneshot — Single Value Return
```rust
use tokio::sync::oneshot;

let (tx, rx) = oneshot::channel::<Result<User, Error>>();

// Worker task
tokio::spawn(async move {
    let result = expensive_query().await;
    let _ = tx.send(result); // ignore if receiver dropped
});

// Await result
let user = rx.await??;
```

---

## Concurrent Execution

```rust
// Run two futures concurrently, wait for both
let (users, orders) = tokio::try_join!(
    fetch_users(&pool),
    fetch_orders(&pool),
)?;

// Run N futures concurrently
use futures::future::join_all;

let handles: Vec<_> = ids.iter()
    .map(|id| fetch_user(&pool, *id))
    .collect();
let results: Vec<_> = join_all(handles).await;

// With error short-circuit
use futures::future::try_join_all;
let users = try_join_all(ids.iter().map(|id| fetch_user(&pool, *id))).await?;

// Bounded concurrency with FuturesUnordered
use futures::stream::{FuturesUnordered, StreamExt};

let mut tasks = FuturesUnordered::new();
for id in ids {
    tasks.push(process(id));
    if tasks.len() >= 10 { // max 10 concurrent
        tasks.next().await;
    }
}
while tasks.next().await.is_some() {}
```

---

## select! — Race Futures

```rust
tokio::select! {
    result = operation_a() => {
        // operation_a completed first
        handle_a(result)?;
    }
    result = operation_b() => {
        handle_b(result)?;
    }
    _ = tokio::time::sleep(Duration::from_secs(5)) => {
        return Err(Error::Timeout);
    }
}
```

**Cancellation safety warning:** When a `select!` branch is not selected, the future is dropped (cancelled). Ensure futures are cancellation-safe:
- Reading from channels: safe
- Writing to channels: may lose data if cancelled mid-send
- Database operations with transactions: use `select!` outside transaction

---

## Task Management

```rust
// Spawn background task
let handle: JoinHandle<()> = tokio::spawn(async move {
    loop {
        process_queue().await;
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
});

// Cancel task
handle.abort();

// Wait for task
match handle.await {
    Ok(result) => { /* task completed */ }
    Err(e) if e.is_cancelled() => { /* task was aborted */ }
    Err(e) => { /* task panicked */ }
}

// Spawn blocking (CPU-bound or blocking I/O)
let result = tokio::task::spawn_blocking(|| {
    expensive_cpu_work()  // runs on dedicated thread pool
}).await?;
```

---

## Timeout Patterns

```rust
use tokio::time::{timeout, Duration};

// Timeout a single operation
let result = timeout(Duration::from_secs(5), fetch_data())
    .await
    .map_err(|_| Error::Timeout)?;

// Timeout with fallback
let data = timeout(Duration::from_millis(200), cache.get(key))
    .await
    .unwrap_or(None) // timeout = cache miss
    .or_else(|| db_fallback(key));
```

---

## Backpressure with Semaphore

```rust
use tokio::sync::Semaphore;
use std::sync::Arc;

let semaphore = Arc::new(Semaphore::new(10)); // max 10 concurrent

let handles: Vec<_> = requests.into_iter().map(|req| {
    let sem = semaphore.clone();
    tokio::spawn(async move {
        let _permit = sem.acquire().await.expect("semaphore closed");
        process_request(req).await
        // permit dropped here, slot freed
    })
}).collect();
```

---

## Async Streams

```rust
use futures::StreamExt;
use sqlx::Row;

// Stream large result sets without loading all into memory
let mut stream = sqlx::query("SELECT id, data FROM large_table")
    .fetch(&pool);

while let Some(row) = stream.next().await {
    let row = row?;
    let id: Uuid = row.get("id");
    process_row(id).await?;
}
```

---

## Common Async Mistakes

| Mistake | Problem | Fix |
|---------|---------|-----|
| `std::thread::sleep` in async | Blocks entire thread | `tokio::time::sleep` |
| `std::fs::read_file` in async | Blocks thread | `tokio::fs::read` or `spawn_blocking` |
| `std::sync::Mutex` across `.await` | Deadlock risk | `tokio::sync::Mutex` or drop before await |
| `tokio::spawn` without storing handle | Task leak | Store handle or explicitly detach |
| `loop { rx.recv().await }` without break | Infinite loop on closed channel | Check for `None` → `break` |
| `select!` with non-cancel-safe future | Data loss | Move state out, or use flags |
