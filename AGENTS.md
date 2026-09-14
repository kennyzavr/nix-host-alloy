# Alloy Agent Development Guide (AGENTS.md)

This is a high-density, technical guide for AI agents. **DO NOT** treat this as a tutorial. It is a system context and a set of strict rules for interacting with the Alloy codebase.

## ❗ Core Principle: Declarative Definition, Imperative Management

The Alloy framework splits infrastructure management into two distinct parts:

1.  **Declarative Definition (Nix):** The entire infrastructure topology, including hosts, containers (jails), networks (overlays), services, and their relationships, is defined declaratively in Nix modules (`*.nix`). The output of this Nix evaluation is a *desired state* configuration.
2.  **Imperative Management (Python CLI):** A Python-based CLI, `alloy-cli`, is used to manage the *stateful* and *secret* parts of the infrastructure (e.g., generating TLS keys, setting fact values, rekeying secrets). It operates on the user's local Git repository (the workspace).

**Your primary role is to modify the Nix declarations. You will rarely, if ever, need to modify the `alloy-cli` Python code.**

---

## Architecture & Mental Model

The data flow is unidirectional and crucial to understand:

**`User's flake.nix` -> `Nix Evaluation` -> `alloy-state.json` -> `alloy-cli` -> `User's Workspace (Git repo)`**

1.  **Nix Evaluation:** When Nix evaluates the user's `flake.nix`, it uses the Alloy module system (`modules/`) to build a complete picture of the infrastructure.
2.  **State Generation:** A special module (`modules/core/cli.nix`) captures this configuration into a single JSON file (`alloy-state.json`) inside the `/nix/store`. This JSON is the **single source of truth** for the CLI.
3.  **CLI Execution:** The `alloy-cli` is a Python application that is wrapped by Nix. This wrapper injects the path to `alloy-state.json` via the `ALLOY_STATE_FILE` environment variable.
4.  **Workspace Interaction:** The CLI reads the desired state from the JSON file and then performs actions (reading/writing files) in the user's current working directory, which is expected to be the root of the Git repository.

### Core Entities & Their Homes

-   **`hosts`**: Physical/virtual machines. Defined in `modules/core/hosts.nix`.
-   **`jails`**: Systemd-nspawn containers. Defined in `modules/core/jails.nix`.
-   **`overlays`**: WireGuard-based mesh networks. Defined in `modules/core/overlays.nix`.
-   **`endpoints`**: Abstract service entry points with targets and load balancing. Defined in `modules/core/endpoints.nix`.
-   **`dns`**: Zones and records. Defined in `modules/core/dns.nix`.
-   **`tls`**: Certificates and CAs. Defined in `modules/core/tls/`.
-   **`secrets`**: Age-encrypted data. Master secrets and per-node rekeyed secrets. Defined in `modules/core/secrets.nix`.
-   **`facts`**: Plain-text, version-controlled data. Defined in `modules/core/facts.nix`.
-   **`generators`**: Scripts to produce secrets/facts. Defined in `modules/core/generators.nix`.
-   **`indexes`**: Unique integer allocation for resources. Defined in `modules/core/indexes.nix`.

---

## The Alloy Module System: Interfaces & Implementations

The module system is the heart of the framework. It is **NOT** the standard NixOS module system, but a layer on top of it.

-   **Core Modules (`modules/core/`)**: These files define the **interfaces** and **abstractions**. They create `options` for entities like `hosts`, `jails`, `endpoints`, etc. They contain the logic to translate these high-level definitions into concrete NixOS configurations. For example, `modules/core/jails.nix` takes `config.jails` and generates the necessary `containers."alloy-jail-..."` NixOS options.
-   **Service Modules (`modules/services/`)**: These files are **consumers** of the core interfaces. They define high-level services (e.g., `services.ca`, `services.http-edge`) and, in their implementation, they create instances of the core entities. For example, `modules/services/ca.nix` creates a `jails."ca-..."` instance, an `endpoints."ca-..."` instance, and `generators` for the CA certificates.

This creates a clean separation: services declare *what* they need (a jail, an endpoint), and the core modules handle *how* to implement it.

---

## Contract & Module Anatomy: Creating a New Service

To add a new service, `my-new-service`, you must follow this contract precisely.

1.  **Create the service module file:** `modules/services/my-new-service.nix`

2.  **Use this template:**

    ```nix
    # modules/services/my-new-service.nix
    { flake.alloyModules.services = { alib, lib, config, ... }:
      let
        alloy = config; # Alias for the global config

        # 1. Define the options for your service instances
        serviceSubmodule = { config, name, ... }: {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            host = lib.mkOption {
              type = lib.types.str;
              description = "The host where this service jail will run.";
            };
            someOption = lib.mkOption {
              type = lib.types.str;
            };
            # ... other service-specific options
          };
        };

        # 2. Implement the logic to create core entities from a service instance
        mkService = srvName: srv: {
          # This function returns an attribute set of core entity definitions.
          # Example:
          jails."my-new-service-${srvName}" = {
            host = srv.host;
            nixosModule = { pkgs, ... }: {
              # ... NixOS configuration for the jail
              services.nginx.enable = true;
            };
          };

          endpoints."my-new-service-${srvName}" = {
            port = 80;
            targets = [{
              overlay = "main"; # Example
              ipv6 = alloy.jails."my-new-service-${srvName}".overlays.main.ipv6;
            }];
          };

          # Add assertions to validate user configuration
          assertions = [{
            assertion = builtins.hasAttr srv.host alloy.hosts;
            message = "[Alloy] my-new-service '${srvName}': host '${srv.host}' is not defined.";
          }];
        };

      in
      {
        # 3. Declare the top-level option for your service
        options.services."my-new-service" = lib.mkOption {
          default = {};
          type = lib.types.attrsOf (lib.types.submodule serviceSubmodule);
        };

        # 4. Process all enabled service instances and merge their generated configs
        config =
          let
            # Process all defined instances of your service
            services = lib.pipe alloy.services."my-new-service" [
              (lib.filterAttrs (_: srv: srv.enable))
              (lib.mapAttrsToList mkService)
            ];
          in
          {
            # Merge the generated core entities into the global config
            jails = lib.mkMerge (lib.map (s: s.jails or {}) services);
            endpoints = lib.mkMerge (lib.map (s: s.endpoints or {}) services);
            assertions = lib.mkMerge (lib.map (s: s.assertions or []) services);
            # ... merge other entity types your service creates (facts, secrets, etc.)
          };
      };
    }
    ```

3.  **Add your new module to `modules/services/default.nix`**.

---

## Code Style & Idioms (Nix)

-   **Formatter:** The project uses `nixfmt`. All contributions must be formatted with it.
-   **Arguments:** Always destructure function arguments: `{ lib, config, pkgs, ... }`.
-   **Custom Library:** Use the custom library via the `alib` argument (e.g., `alib.types.zoneNode`). It is defined in `lib/`.
-   **Collections:** Use `lib.mapAttrsToList`, `lib.pipe`, and `lib.mkMerge` to process attribute sets of entities. Avoid manual recursion.

---

## ⛔ Gotchas & Strict Constraints (TABOO LIST)

**Violating these rules will break the system. Memorize them.**

1.  **NEVER modify generated files manually.** Files in `facts/`, `secrets/hosts/`, and `secrets/jails/` are managed by `alloy-cli`. Use commands like `alloy facts set`, `alloy secrets rekey`, and `alloy generators run`.
2.  **NEVER define a NixOS module directly in a service.** Services MUST define instances of core entities (`jails`, `endpoints`, `tls.certs`, etc.). The core modules (`modules/core/`) are responsible for generating the final NixOS configuration.
3.  **ALWAYS use `alloy.dns.resolveNode` to get a full domain string.** Do not manually concatenate zone and name parts (e.g., `"${name}.${zone}"`). The function is available as `alloy.dns.resolveNode`.
4.  **NEVER use `builtins.import <nixpkgs>`.** Always use the `pkgs` argument passed into the module or function.
5.  **ALWAYS use `alib.types` for custom types.** Do not redefine types like `zoneNode` or `ip.v4addr`. The library is available as the `alib` argument.
6.  **NEVER reference `config.age.secrets` directly for a jail's secret.** A jail runs in a separate mount namespace. The core `secrets` module handles bind-mounting secrets from the host into the jail via `agenix`. You must use the path provided by the jail's `secrets` submodule (e.g., `config.secrets.my-secret.path`).
7.  **ALWAYS define `assertions` in your modules.** This is the primary mechanism for providing clear error messages to the user for invalid configurations.
8.  **NEVER assume an entity exists.** When cross-referencing (e.g., `alloy.hosts.${name}`), always add an assertion to check for its existence (`builtins.hasAttr name alloy.hosts`).
9.  **A service instance is processed by `mkService` function.** This function must return an attribute set where keys are the names of core entities (`jails`, `endpoints`, `facts`, etc.) and values are the definitions for those entities.
10. **The CLI state is IMMUTABLE.** The `alloy-cli` reads from a static JSON file. To update the CLI's view of the world, the user's Nix flake must be re-evaluated (e.g., via `nix build`).
