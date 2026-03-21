### 1. Plan Mode Default
- Enter plan mode for ANY not-trivial task (3+ steps or architectural decisions)
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity

### 2. Self-Improvement Loop
- After ANY correction from the user: update `tasks/lessons.md` with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until the mistake rate drops
- Review lessons at session start for a project

### 3. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 4. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes. Don't overengineer
- Challenge your own work before presenting it

### 5. Skills usage
- Use skills for any task that requires a capability
- Load skills from `.claude/skills/`
- Invoke skills with natural language
- Each skill is one independent capability

### 6. Subagents usage
- Use subagents liberally to keep the main context window clean
- Load subagents from `.claude/agents/`
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution on a given tech stack

## Core Principles
- **Simplicity First**: Make every change as simple as possible. Impact minimal code
- **No Laziness**: Find root causes. No temporary fixes. Senior developer standards

## Project General Instructions

- Always use the latest stable versions of crates from crates.io.
- Always write Rust code using idiomatic patterns: ownership, borrowing, error handling with `Result`/`?`.
- Always use Cargo for dependency and build management.
- Always create test cases for the generated code — both unit tests (`#[test]`) and integration tests in `tests/`.
- Always generate the GitHub Actions CI pipeline in `.github/workflows/` to verify the code.
- Minimize the amount of code generated.
- The Cargo package name must be the same as the parent directory name (snake_case).
- Use semantic versioning for the Cargo package. Each time you generate a new version, bump the PATCH section.
- Use `async`/`await` with `tokio` as the async runtime unless a synchronous design is explicitly required.
- Do not use `unwrap()` or `expect()` in production code — propagate errors with `?` and custom error types.
- Use `thiserror` for library error types and `anyhow` for application-level error handling.
- Generate the Docker Compose file to run all components used by the application.
- Update README.md each time you generate a new version.
- Prefer `sqlx` for database access with compile-time checked queries.
- Use `axum` as the default web framework for HTTP services.
- Enable `tracing` with `tracing-subscriber` for structured logging.
