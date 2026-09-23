# Alloy CLI (Rust) -- Agent Reference

This document is a technical guide for AI agents working on the `alloy-cli` (Rust) codebase.
It reflects the new Rust architecture that replaces the legacy Python CLI. Read this fully before making any changes.

---

## 1. Architectural Layers

The Rust CLI strictly follows a 4-layer architecture with Dependency Injection, avoiding tightly coupled side effects in business logic.

```
packages/cli/src/
  cli/           (Presentation Layer)
    commands/    - clap handlers, output formatting via `ctx.ui`. NO business logic here.
    di.rs        - `AppContext` (Dependency Injection container).
    mod.rs       - `clap` entry points and CLI parser definition.
  services/      (Business / Application Layer)
    facts.rs     - Core business logic, error aggregation, state mutation.
    secrets.rs
    generators.rs
    indexes.rs
  infra/         (Infrastructure Layer)
    fs.rs, git.rs, editor.rs, ui.rs, nix.rs, rage.rs, runner.rs 
                 - Adapters for side effects (I/O, Git, QEMU, Terminal, etc.)
  error.rs       - Custom `ErrorCollection`, `StringError`, and `WrapErrExt` trait.
  domain/        (Domain Layer)
    models.rs    - Deserialized `alloy-state.json` structs.
    ports.rs     - Traits defining infrastructure contracts (`FileSystem`, `Git`, `CommandRunner`, etc.)
```

---

## 2. Key Principles & Patterns

### 2.1 Dependency Injection (DI)
- Commands in `cli/commands/` receive an `&AppContext`.
- `AppContext` initializes and holds all infrastructure adapters (`LocalFs`, `GitCli`, `TerminalUi`, `NixAdapter`, etc.).
- Commands obtain business services via factory methods on the context (e.g., `ctx.facts_service()`, `ctx.secrets_service()`).
- Services (`services/*.rs`) do **NOT** depend on concrete infra structs. They rely entirely on trait bounds wrapped in `Arc` (e.g., `nix: Arc<dyn NixEvaluator>`, `fs: Arc<dyn FileSystem>`) defined in `domain::ports`. This keeps services completely free of lifetime constraints.

### 2.2 Relative Paths & `workspace_root` Isolation
- The presentation (`cli/`) and business (`services/`) layers **DO NOT KNOW** about absolute filesystem paths or the `workspace_root`.
- All paths handled by services are purely relative to the workspace repository.
- The translation to absolute paths happens **exclusively** in the `infra/` layer (e.g., inside `LocalFs` and `GitCli`). Do not leak `workspace_root` into services or commands.

### 2.3 UI and Terminal Output
- `TerminalUi` (`infra/ui.rs`) handles all console output (`print_error`, `print_info`, `print_step`, `print_skip`, `print_ok`, `print_table`).
- **Formatting Constraints**: The UI module automatically colorizes specific patterns in text. Backticks (`` `name` ``) are colored **Yellow**, and single quotes (`'path'`) are colored **Magenta**. Always use these markers when printing entity names and file paths.
- **Do NOT** use `println!`, `eprintln!`, or `miette` in the command layer. Always use `ctx.ui.print_*`.
- **Do NOT** pass `depth` parameters manually across modules. `TerminalUi` encapsulates the nesting depth logic internally.

### 2.4 Error Handling (thiserror + Aggregation)
- The project uses `thiserror` for all errors. Do not use `eyre` or `anyhow`. Define structured error enums in the module where they originate.
- **Aggregation over Fail-Fast**: When processing lists of items (e.g., `secrets rekey`, `generators run`, or resolving entities via `collect`), services return a custom `ErrorCollection<E>` instead of `Vec<E>` via `Result<Vec<T>, CollectionError>`.
- **Formatting**: The `error.rs` module manages error stringifying, displaying multiple errors with bullet dashes (`-`) and correctly indenting nested error sources using `#[source]`.
- **Context Wrapping**: Use the `WrapErrExt` trait (from `error.rs`) to attach context (like generator or secret names in backticks) to existing errors using `.wrap_err()` or `.wrap_err_with()`.
- **Do NOT manually format errors** (e.g., manually joining lines with `\n` in the CLI layer). Build the tree of `thiserror` variants and let `ctx.ui.print_error(&e)` print the complete trace.
- **Entity Lookup**: Use `service.get(&name)` or `service.find(&name)`. It returns a standardized `NotFoundError` from the service.

### 2.5 Editing and Temp Files
- Never write ad-hoc `NamedTempFile` and `$EDITOR` spawning logic in the command handlers.
- Use `crate::infra::editor::SystemEditor::edit(&data)` which safely encapsulates the lifecycle of creating a temp file, running the user's preferred editor, and detecting changes.

### 2.6 Atomicity & Git Integration
- File writes (e.g., creating a fact or secret) must check if the workspace is a Git repository (`git.is_repo()`) **before** modifying the file on disk. If not a repo (and not bypassed), it must return an error and abort the write.

### 2.7 State Management & Records
- Services do **NOT** store `&'a State` in their struct definition.
- The Nix state is typically loaded lazily inside service methods *only when required* (e.g., inside `collect`) using `ctx.nix.load_state()?`.
- **Performance Opt-out**: For heavy loop-based operations (like in `generators` plan execution), services may accept `&State` directly (e.g. `service.plan(&state, ...)`), allowing the CLI to load state once per loop instead of the service causing N internal evaluations.
- Methods that don't need state (e.g. `exists()`) operate directly without incurring the `nix eval` penalty.
- Records returned by services (like `HostRecord`, `SecretRecord`, `GeneratorRecord`) own their data. They use `Arc<str>` or `String` for names and own their internal state structs. This completely eliminates lifetime propagation (`<'a>`) across the domain layer.

---

## 3. Data Flow

1. User invokes `alloy <command>`.
2. `cli/mod.rs` parses arguments via `clap`.
3. `cli/mod.rs` initializes `AppContext` (infra adapters).
4. Command handler in `cli/commands/*.rs` is called with `args` and `ctx`.
5. Handler instantiates a service using a context factory (e.g., `let service = ctx.secrets_service()`).
6. Handler invokes service methods (e.g., `service.get(name)` or `service.collect(...)`).
7. The service internally calls `nix.load_state()?` only if the operation requires reading the Nix state.
8. Handler iterates over the results or errors and reports them via `ctx.ui`.
