# Background Worker Patterns Reference

## Simple Background Task with tokio::spawn

```rust
use tokio::time::{interval, Duration};
use tokio::sync::watch;

/// Spawn a background task with graceful shutdown.
pub fn spawn_background_task(
    pool: sqlx::PgPool,
    mut shutdown: watch::Receiver<()>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(60));
        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    if let Err(e) = process_pending_jobs(&pool).await {
                        tracing::error!(error = %e, "Background job failed");
                    }
                }
                _ = shutdown.changed() => {
                    tracing::info!("Background worker shutting down");
                    break;
                }
            }
        }
    })
}

// Integration with main.rs
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let pool = sqlx::PgPool::connect(&db_url).await?;

    let (shutdown_tx, shutdown_rx) = watch::channel(());

    // Spawn workers
    let worker_handle = spawn_background_task(pool.clone(), shutdown_rx.clone());

    // Start HTTP server
    let server = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown_signal().await;
            let _ = shutdown_tx.send(()); // Signal all workers
        });

    server.await?;

    // Wait for workers to drain
    worker_handle.await?;

    Ok(())
}
```

---

## Database-Backed Job Queue

```sql
-- migrations/20240201000001_create_jobs.sql
CREATE TYPE job_status AS ENUM ('pending', 'running', 'completed', 'failed', 'dead');

CREATE TABLE jobs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    job_type      TEXT NOT NULL,
    payload       JSONB NOT NULL DEFAULT '{}',
    status        job_status NOT NULL DEFAULT 'pending',
    attempts      INT NOT NULL DEFAULT 0,
    max_attempts  INT NOT NULL DEFAULT 3,
    scheduled_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at    TIMESTAMPTZ,
    completed_at  TIMESTAMPTZ,
    error_message TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_jobs_pending ON jobs(scheduled_at)
    WHERE status = 'pending';
CREATE INDEX idx_jobs_status ON jobs(status);
```

```rust
use sqlx::PgPool;
use uuid::Uuid;
use serde::{Deserialize, Serialize};

#[derive(Debug, sqlx::FromRow)]
pub struct Job {
    pub id: Uuid,
    pub job_type: String,
    pub payload: serde_json::Value,
    pub status: JobStatus,
    pub attempts: i32,
    pub max_attempts: i32,
}

/// Claim the next pending job atomically (FOR UPDATE SKIP LOCKED).
pub async fn claim_next_job(pool: &PgPool) -> Result<Option<Job>, sqlx::Error> {
    sqlx::query_as!(
        Job,
        r#"
        UPDATE jobs
        SET status = 'running', started_at = NOW(), attempts = attempts + 1
        WHERE id = (
            SELECT id FROM jobs
            WHERE status = 'pending' AND scheduled_at <= NOW()
            ORDER BY scheduled_at
            FOR UPDATE SKIP LOCKED
            LIMIT 1
        )
        RETURNING id, job_type, payload, status as "status: JobStatus",
                  attempts, max_attempts
        "#
    )
    .fetch_optional(pool)
    .await
}

pub async fn complete_job(pool: &PgPool, id: Uuid) -> Result<(), sqlx::Error> {
    sqlx::query!(
        "UPDATE jobs SET status = 'completed', completed_at = NOW() WHERE id = $1",
        id
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn fail_job(pool: &PgPool, id: Uuid, error: &str, max_attempts: i32, attempts: i32) -> Result<(), sqlx::Error> {
    let new_status = if attempts >= max_attempts { "dead" } else { "pending" };
    sqlx::query!(
        "UPDATE jobs SET status = $1::job_status, error_message = $2, scheduled_at = NOW() + interval '30 seconds' * $3 WHERE id = $4",
        new_status,
        error,
        attempts, // exponential-ish backoff
        id
    )
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn enqueue_job(pool: &PgPool, job_type: &str, payload: &serde_json::Value) -> Result<Uuid, sqlx::Error> {
    let row = sqlx::query!(
        "INSERT INTO jobs (job_type, payload) VALUES ($1, $2) RETURNING id",
        job_type,
        payload
    )
    .fetch_one(pool)
    .await?;
    Ok(row.id)
}
```

---

## Worker Loop (Polling)

```rust
pub async fn worker_loop(
    pool: PgPool,
    mut shutdown: watch::Receiver<()>,
) {
    tracing::info!("Job worker started");

    loop {
        tokio::select! {
            _ = shutdown.changed() => {
                tracing::info!("Job worker shutting down");
                break;
            }
            _ = process_one_job(&pool) => {}
        }
    }
}

async fn process_one_job(pool: &PgPool) {
    match claim_next_job(pool).await {
        Ok(Some(job)) => {
            let span = tracing::info_span!("job", id = %job.id, r#type = %job.job_type);
            let _guard = span.enter();

            tracing::info!("Processing job");

            let result = match job.job_type.as_str() {
                "send_welcome_email" => handle_welcome_email(&job.payload).await,
                "generate_report" => handle_generate_report(&job.payload).await,
                unknown => {
                    tracing::error!(job_type = %unknown, "Unknown job type");
                    Err(anyhow::anyhow!("unknown job type: {unknown}"))
                }
            };

            match result {
                Ok(()) => {
                    if let Err(e) = complete_job(pool, job.id).await {
                        tracing::error!(error = %e, "Failed to mark job complete");
                    }
                    tracing::info!("Job completed");
                }
                Err(e) => {
                    tracing::error!(error = %e, "Job failed");
                    let _ = fail_job(pool, job.id, &e.to_string(), job.max_attempts, job.attempts).await;
                }
            }
        }
        Ok(None) => {
            // No jobs available — back off
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        Err(e) => {
            tracing::error!(error = %e, "Failed to claim job");
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }
}
```

---

## Cron-like Scheduling

```toml
[dependencies]
tokio-cron-scheduler = "0.13"
```

```rust
use tokio_cron_scheduler::{Job, JobScheduler};

pub async fn start_scheduler(pool: PgPool) -> anyhow::Result<JobScheduler> {
    let scheduler = JobScheduler::new().await?;

    // Every hour — cleanup expired sessions
    let pool_clone = pool.clone();
    scheduler.add(Job::new_async("0 0 * * * *", move |_uuid, _lock| {
        let pool = pool_clone.clone();
        Box::pin(async move {
            if let Err(e) = cleanup_expired_sessions(&pool).await {
                tracing::error!(error = %e, "Session cleanup failed");
            }
        })
    })?).await?;

    // Daily at 2am — generate reports
    let pool_clone = pool.clone();
    scheduler.add(Job::new_async("0 0 2 * * *", move |_uuid, _lock| {
        let pool = pool_clone.clone();
        Box::pin(async move {
            if let Err(e) = generate_daily_report(&pool).await {
                tracing::error!(error = %e, "Daily report failed");
            }
        })
    })?).await?;

    scheduler.start().await?;
    Ok(scheduler)
}
```

---

## Concurrent Worker Pool

```rust
use tokio::sync::Semaphore;
use std::sync::Arc;

/// Run N concurrent workers processing from the same job queue.
pub async fn start_worker_pool(
    pool: PgPool,
    concurrency: usize,
    shutdown: watch::Receiver<()>,
) -> Vec<tokio::task::JoinHandle<()>> {
    let semaphore = Arc::new(Semaphore::new(concurrency));

    (0..concurrency)
        .map(|i| {
            let pool = pool.clone();
            let shutdown = shutdown.clone();
            let sem = semaphore.clone();

            tokio::spawn(async move {
                tracing::info!(worker = i, "Worker started");
                worker_loop_with_semaphore(pool, shutdown, sem).await;
                tracing::info!(worker = i, "Worker stopped");
            })
        })
        .collect()
}

async fn worker_loop_with_semaphore(
    pool: PgPool,
    mut shutdown: watch::Receiver<()>,
    semaphore: Arc<Semaphore>,
) {
    loop {
        let permit = tokio::select! {
            permit = semaphore.acquire() => permit.expect("semaphore closed"),
            _ = shutdown.changed() => break,
        };

        process_one_job(&pool).await;
        drop(permit);
    }
}
```

---

## Event-Driven Worker (Channel-Based)

```rust
use tokio::sync::mpsc;

#[derive(Debug)]
pub enum WorkerEvent {
    SendEmail { to: String, template: String },
    ProcessPayment { order_id: Uuid },
    GenerateReport { report_type: String },
}

pub fn spawn_event_worker(
    mut rx: mpsc::Receiver<WorkerEvent>,
    pool: PgPool,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let span = tracing::info_span!("worker_event", event = ?event);
            let _guard = span.enter();

            let result = match event {
                WorkerEvent::SendEmail { to, template } => {
                    send_email(&to, &template).await
                }
                WorkerEvent::ProcessPayment { order_id } => {
                    process_payment(&pool, order_id).await
                }
                WorkerEvent::GenerateReport { report_type } => {
                    generate_report(&pool, &report_type).await
                }
            };

            if let Err(e) = result {
                tracing::error!(error = %e, "Event processing failed");
            }
        }
        tracing::info!("Event worker shut down (channel closed)");
    })
}

// Enqueue from handler
pub async fn create_order_handler(
    State(state): State<AppState>,
    Json(req): Json<CreateOrderRequest>,
) -> Result<(StatusCode, Json<OrderResponse>), AppError> {
    let order = services::orders::create(&state.pool, req).await?;

    // Fire-and-forget background work
    let _ = state.worker_tx.send(WorkerEvent::ProcessPayment {
        order_id: order.id,
    }).await;

    Ok((StatusCode::CREATED, Json(OrderResponse::from(order))))
}
```

---

## Pattern Selection Guide

| Need | Pattern |
|------|---------|
| Periodic task (cleanup, reports) | Cron scheduler (`tokio-cron-scheduler`) |
| Reliable job processing with retries | Database-backed queue (`FOR UPDATE SKIP LOCKED`) |
| Fire-and-forget from handlers | Channel-based (`mpsc`) |
| High throughput parallel work | Worker pool with `Semaphore` |
| Simple periodic check | `tokio::time::interval` + `tokio::select!` |

## Checklist

- [ ] All workers respect shutdown signal (`watch::Receiver`)
- [ ] Failed jobs retry with backoff (not infinite loops)
- [ ] Dead-letter handling for jobs exceeding `max_attempts`
- [ ] Worker panics caught (wrap in `tokio::spawn` + `JoinHandle`)
- [ ] Metrics: jobs processed, failed, queue depth, processing time
- [ ] No blocking I/O in async worker (use `spawn_blocking` if needed)
- [ ] Database connections returned promptly (no long-held transactions)
