# Rust Code Review Skill

Systematic code review for Rust with ownership safety, async correctness, idiomatic patterns, and security checks.

## When to Use
- User says "review code", "check this PR", "code review"
- Before merging Rust code changes
- When auditing `unsafe` blocks
- When reviewing async Rust correctness

## Review Workflow

### Step 1: Quick Scan (run these commands first)
```bash
cargo clippy -- -D warnings          # All warnings as errors
cargo audit                           # Check for CVE in dependencies
grep -rn "unwrap\(\)\|expect(" src/  # Find panic-prone calls
grep -rn "unsafe" src/               # Locate all unsafe blocks
```

### Step 2: Systematic Review by Category

## Category 1: Ownership & Borrowing

| Issue | Anti-pattern | Idiomatic |
|-------|-------------|-----------|
| Unnecessary clone | `fn f(s: String) -> String { s.clone() }` | `fn f(s: &str) -> &str { s }` |
| Clone in loop | `items.iter().map(\|i\| i.name.clone())` | `items.iter().map(\|i\| &i.name)` |
| Premature Arc | `Arc<String>` everywhere | Pass references, use Arc only for shared ownership |
| Fighting borrow checker | Workarounds with indexes | Redesign data structure |

**Check:**
- [ ] No unnecessary `.clone()` in hot paths
- [ ] References used where ownership not needed
- [ ] Lifetime annotations correct and minimal
- [ ] No `Rc<RefCell<T>>` in async code (use `Arc<Mutex<T>>` or `tokio::sync`)

## Category 2: Error Handling

| Issue | Anti-pattern | Idiomatic |
|-------|-------------|-----------|
| Panic in prod | `result.unwrap()` | `result?` or `result.context("msg")?` |
| Lost context | `result?` alone | `result.context("loading config")?` |
| `Box<dyn Error>` at boundary | Library returns `Box<dyn Error>` | Define typed error enum with `thiserror` |
| Swallowed errors | `let _ = risky_call();` | Handle or explicitly ignore with comment |

**Check:**
- [ ] No `unwrap()`/`expect()` in production code paths
- [ ] Library crates use `thiserror` error enums
- [ ] Application code uses `anyhow` with `.context()`
- [ ] All error variants in `thiserror` enum handled or documented
- [ ] HTTP errors map to correct status codes with user-safe messages

## Category 3: Unsafe Code

Every `unsafe` block must answer:
1. **Why is this safe?** — comment explaining the invariant maintained
2. **What is the contract?** — what callers must guarantee
3. **Is there a safe alternative?** — if yes, use it

```rust
// BAD: unsafe without justification
unsafe { ptr.as_ref().unwrap() }

// GOOD: documented invariant
// SAFETY: ptr is guaranteed non-null by the constructor invariant.
// The value lives at least as long as 'a per the type parameter constraint.
let r: &'a T = unsafe { &*ptr };
```

**Check:**
- [ ] Every `unsafe` block has a `// SAFETY:` comment
- [ ] `unsafe fn` has `# Safety` section in doc comment
- [ ] FFI types correctly sized and aligned
- [ ] No uninitialized memory access
- [ ] No data races (check `Send`/`Sync` impls)

## Category 4: Async Correctness

| Issue | Description | Fix |
|-------|-------------|-----|
| Non-cancel-safe | Holding state across `.await` in `select!` | Document cancellation safety or restructure |
| Lock across await | `let _guard = mutex.lock().await; do_io().await;` | Drop guard before await |
| Blocking in async | `std::fs::read()` in async fn | Use `tokio::fs::read()` or `spawn_blocking` |
| Task leak | `tokio::spawn(...)` result ignored | Store `JoinHandle` or use `tokio::spawn` carefully |
| Wrong mutex | `std::sync::Mutex` in async | `tokio::sync::Mutex` for async guards |

**Check:**
- [ ] No blocking I/O in async functions
- [ ] `std::sync::Mutex` not held across `.await`
- [ ] `tokio::spawn` handles stored or fire-and-forget documented
- [ ] `select!` branches are cancellation-safe
- [ ] Timeout handling prevents indefinite waits

## Category 5: Idiomatic Rust

| Anti-pattern | Idiomatic |
|-------------|-----------|
| `if x == true` | `if x` |
| `match x { true => a, false => b }` | `if x { a } else { b }` |
| `return x;` at end of fn | `x` (expression) |
| `.iter().filter().map()` with redundant collect | Use iterator chains lazily |
| Indexing with `vec[i]` | `.get(i)` for safe access |
| `impl Trait` for private fn | Concrete type preferred |
| Redundant `&` in `for &x in iter` | Use `.iter().copied()` or `.cloned()` |

## Category 6: Performance

| Issue | Check | Fix |
|-------|-------|-----|
| String allocation | `format!("{}", x)` in hot path | `write!` into existing buffer |
| Regex in loop | `Regex::new(...)` per iteration | Static `lazy_static!` or `once_cell::sync::Lazy` |
| Vec without capacity | `Vec::new()` when size known | `Vec::with_capacity(n)` |
| Repeated HashMap lookup | `.contains_key` + `.insert` | `.entry().or_insert()` |
| N+1 queries | Loop with DB query inside | Batch query outside loop |

## Category 7: Security

- [ ] No secrets/tokens in source code
- [ ] User input validated before use (SQL injection via sqlx macros, HTML escaping)
- [ ] `zeroize` used for sensitive data in memory
- [ ] TLS configured with `rustls` (not `openssl` without good reason)
- [ ] `cargo audit` passes — no known CVEs
- [ ] Cryptographic operations use vetted crates (`ring`, `argon2`, `bcrypt`)
- [ ] No timing vulnerabilities in comparisons (`subtle::ConstantTimeEq`)

## Category 8: Testing

- [ ] All public API functions have tests
- [ ] Error paths tested (not just happy paths)
- [ ] Async functions tested with `#[tokio::test]`
- [ ] No `sleep()` in tests — use `tokio::time::pause()`
- [ ] Integration tests in `tests/` use public API only
- [ ] Property tests with `proptest` for pure functions with invariants

## Severity Guidelines

| Severity | Examples |
|----------|---------|
| **Critical** | Unsound unsafe, data race, panic in production, SQL injection |
| **Major** | `unwrap()` in prod, blocking in async, error swallowed, memory leak |
| **Minor** | Unnecessary clone, missing error context, suboptimal algorithm |
| **Nit** | Naming, formatting (defer to `rustfmt`), doc spelling |

## Output Format

```
## Rust Code Review Summary

**Files reviewed:** N
**Critical:** N | **Major:** N | **Minor:** N | **Nits:** N

### Critical Issues
- `src/db.rs:47` — `unwrap()` on database query: will panic on connection error. Use `?` instead.

### Major Issues
- `src/handlers/auth.rs:23` — `std::sync::Mutex` held across `.await`. Switch to `tokio::sync::Mutex`.

### Minor Issues
- `src/models/user.rs:15` — `.clone()` on `String` unnecessary. Pass `&str` to function.

### Positives
- Error types well-modeled with `thiserror`
- Comprehensive `#[tokio::test]` coverage
```
