# Alloy CLI Architecture (Rust)

The Alloy CLI is the imperative state management and orchestration tool for the Alloy Framework. It has been entirely rewritten in Rust, transitioning away from the old Python-based CLI to achieve better performance, strict typing, and a cleaner architecture.

## Overview

The new CLI architecture is split into three main Rust crates (packages), enforcing a strict separation of concerns:

1. **`alloy-cli` (Presentation Layer)**
   - **Responsibility:** Command-line parsing, argument validation, context initialization, formatting (tables, styles, logs), and error reporting.
   - **Key Components:**
     - `commands/`: Thin handlers for each subcommand (e.g., `generators run`, `qemu run`, `secrets list`).
     - `ui.rs`: Handles rich terminal output using the `owo-colors` crate for styling (step, info, error, ok, skip).
     - `error.rs`: Provides `WrapErrExt` for rich error chains. Errors are wrapped with `.wrap_err("context")` and rendered nicely.
     - `ctx.rs`: The execution context (`Ctx`), holding adapters and state path, passed down to command handlers.
   - **CLI Framework:** Built using `clap` (derive API) for routing and argument parsing.

2. **`alloy-core` (Business Logic / Domain Layer)**
   - **Responsibility:** The heart of the CLI. Contains pure business logic, domain models, algorithms, and orchestration. It has **no knowledge of the external world** (no filesystem paths, no Git, no subprocesses).
   - **Key Components:**
     - `models.rs`: Defines Serde data structures matching the `alloy-state.json` schema exactly.
     - `ports.rs`: Defines traits (interfaces) for external systems (`FileSystem`, `Age`, `GenRunner`, `QemuHost`, `VdeHost`).
     - Module Logic (`secrets.rs`, `indexes.rs`, `gens.rs`, `qemu.rs`, etc.): Implements the "Flat + Targeted Search" pattern (e.g., `find_all` -> returns pool, `find` -> returns single).
   - **Design Rule:** Functions here receive `ctx: &dyn Ctx` and `state: &models::State`. They operate on the models and only interact with the outside world via `ctx`'s ports.

3. **`alloy-infra` (Infrastructure / Data Access Layer)**
   - **Responsibility:** Implements the traits defined in `alloy-core::ports`. Handles file I/O, Git operations, Nix evaluations, subprocess spawns (Rage, QEMU, VDE), and workspace detection.
   - **Key Components:**
     - `nix.rs`: Evaluates `flake.nix`, builds the Nix module tree, produces `alloy-state.json`, and parses it into `models::State`. Caches the state path.
     - `local_fs.rs`: Implements file reading/writing.
     - `qemu.rs`: Implements `QemuHost`, `VdeHost`, and RAII-based drop semantics for processes.
     - `age.rs`: Shells out to `rage` for encrypting/decrypting secrets.

## Execution Flow

```text
1. CLI Entry (`alloy-cli/main.rs`)
   -> Parses arguments (e.g., `alloy qemu run`)
   -> Detects workspace root (via `alloy-infra::Workspace`)
   -> Initializes Adapters (`LocalFs`, `NixAdapter`, `LocalQemuHost`, etc.)
   -> Constructs `Ctx` containing the adapters

2. Command Handler (`alloy-cli/commands/qemu.rs`)
   -> Calls `ctx.nix.load_state_data()` to evaluate Nix config -> gets `models::State`
   -> Resolves requested hosts via `alloy_core::hosts::find(&state, name)`
   -> Calls Core Logic: `alloy_core::qemu::launch(ctx, &state, state_path, &guests)`

3. Core Logic (`alloy-core/qemu.rs`)
   -> Determines which VDE networks are required
   -> Calls `ctx.vde().start(...)` (Dispatches to `alloy-infra`)
   -> Calls `ctx.qemu().launch(...)` (Dispatches to `alloy-infra`)
   -> Waits for processes to finish

4. Infrastructure (`alloy-infra/qemu.rs`)
   -> Spawns `vde_switch` subprocess, waits for socket creation.
   -> Spawns `qemu-system-*` subprocess.
   -> When RAII objects (`LocalVdeSwitch`) go out of scope, the Drop trait automatically kills processes and removes sockets.
```

## Architectural Patterns

### Flat + Targeted Search
Instead of complex nested domain graphs, data is kept flat (as read from `models::State`). When a command operates on an entity, it uses a module's `find(state, name)` or `find_all(state)` to extract strongly-typed abstractions (e.g., `Entity<'s>`). This reduces lifetimes complexity and overhead.

### Trait-Based Dependency Injection (Ports & Adapters)
`alloy-core` never knows *how* a secret is encrypted. It only knows `ctx.age().encrypt(data, recipients)`. `alloy-infra` implements this via `rage` binary. This makes `alloy-core` trivially testable and decoupled from environment specifics.

### RAII Lifecycle Management
Processes (like `vde_switch` and QEMU instances) are managed through Rust's `Drop` trait. Rather than having a `stop()` function, the process dies and cleans up its sockets when the struct instance goes out of scope.

### Error Chaining
Instead of `.map_err(|e| format!("Failed: {}", e))` which destroys the source error, the CLI uses a custom `WrapErrExt` trait.
```rust
// GOOD
do_something().wrap_err("Failed to initialize component")?;

// BAD
do_something().map_err(|e| err_msg(format!("Failed: {}", e)))?;
```
The UI renderer `render_error_chain` walks the `.source()` tree and prints a clean, bulleted error trace.

## VM Subsystem (QEMU / VDE)

The VM subsystem handles testing generated NixOS configurations locally.
- **State mapping:** Core translates the state JSON variants and network configs.
- **L2 Bridge:** VDE (Virtual Distributed Ethernet) creates virtual switches. Controlled by `alloy-infra::qemu::LocalVdeHost`.
- **QEMU:** Foreground-only processes. The CLI inherits stdin/stdout/stderr, so QEMU output streams directly to the user. No detached mode.
- **Cache Dir:** VM state, logs, and disk images are placed in `cache_dir` (default: `./.alloy/vms/<name>/`).

## Error Handling

Errors implement the standard `std::error::Error` trait.
- **Core errors** use `thiserror` to define precise enums (e.g., `FindError`, `LaunchError`).
- **Infra errors** define specific reasons for failure (e.g., `NixError`, `ProcessSpawnError`).
- **CLI layer** wraps these using `WrapErrExt` to provide context (e.g., "Failed to launch VMs") before pushing them to the UI renderer.

## CLI Features

The Alloy CLI manages the imperative state that the declarative Nix modules consume. Here's how core abstractions are handled:

### 1. Facts & Secrets (`alloy facts`, `alloy secrets`)
- **Facts:** Plain-text, versioned strings stored in `facts/` directory (e.g., `alloy facts set my-fact "value"`). They are read by Nix modules (via `builtins.readFile`).
- **Secrets:** Encrypted strings (using `age` / `rage`). Handled in a 3-tier system: Master (global), Host (agenix rekeyed), Jail (bind-mounted).
- **Core Logic:** `alloy-core::secrets` implements `find_all` / `find` (to locate secrets in `models::State`), `set` (encrypt via `ctx.age()`), and `rekey` (batch re-encrypt for new recipients).
- **Presentation:** Handlers print differences, prompt for values (if missing from command line), and format tables showing recipients and identities.

### 2. Indexes (`alloy indexes`)
- **Purpose:** Unique integer allocation backed by fact files, ensuring no gaps/collisions for network ports, VDE instances, etc.
- **Core Logic:** `alloy-core::indexes` calculates minimum available integers based on the Nix-declared `min_value`, `max_value`, and existing `keys`.
- **Flow:** CLI loads state -> fetches current index map -> allocates next free ID -> writes it back via `ctx.fs()` as a fact.

### 3. Generators (`alloy generators`)
- **Purpose:** Script orchestration and Directed Acyclic Graph (DAG) ordering for concrete instances.
- **Core Logic:** 
  - `alloy-core::gens::plan_exec` builds the execution DAG by resolving `wants` and `after` relationships.
  - Generates scripts dynamically if missing, using `ctx.nix().eval_generator_raw(...)`.
- **Execution:** Runs the scripts in parallel/sequential order (via `ctx.gen_runner()`), substituting secrets and facts before execution, and skipping instances that are up-to-date.

## Rust Workspace & Flake Setup

The repository is built around a modern Nix Flake integrated with a Rust workspace.

### Cargo Workspace
- Located in `packages/`, housing the three crates (`alloy-cli`, `alloy-core`, `alloy-infra`). 
- Shared dependencies and workspace-level configuration are defined in the top-level `Cargo.toml`.

### Flake Parts (`flake-parts`)
- The Nix flake is structured using `flake-parts` (`flake.nix` and `parts.nix`), allowing modularity and per-system definitions without boilerplate.
- The Alloy framework modules are exposed via `flake.alloyModules.default`.

### Crane & Rust Overlays
- **Crane:** The `packages/rust.nix` uses `crane` to build the Rust workspace natively. It cleanly separates dependency building (`buildDepsOnly`) from the application build (`buildPackage`), heavily caching Rust compilations in the Nix store.
- **Rust Overlays:** `oxalica/rust-overlay` provides the Rust toolchain (stable), ensuring deterministic and identical compiler versions (`1.98.1` with `rust-analyzer` and `rust-src`) across all developer environments and CI.

### Devshell (`numtide/devshell`)
- Developer environments are unified using `devshell`.
- Integrated across `flake.nix` and `rust.nix`, the shell provides essential tools (`cargo-edit`, `rage`, `git`, `nil`, `vde2`) directly into the `PATH`.
- Developers simply run `nix develop` to enter an environment where `cargo run` works seamlessly with all native dependencies configured.
