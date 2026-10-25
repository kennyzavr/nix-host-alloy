# nix-host-alloy

Alloy is a Nix framework and Rust CLI for managing NixOS infrastructure. Describe hosts, services, and how they connect in a shared configuration. Alloy derives their NixOS configurations and brings together the networking, DNS, certificates, and secrets they need.

The goal is to make infrastructure reusable and composable: a service module can declare where it runs, expose an endpoint, and request certificates or secrets, while common modules handle the configuration needed to connect them.

> **Under active development.** Expect breaking changes, incomplete workflows, and limited documentation. Adapting Alloy to your own infrastructure currently requires familiarity with NixOS and a willingness to read the source and make manual adjustments. It is experimental; use it cautiously on systems you depend on.

## What it can do

- **Hosts and containers:** configure NixOS machines and systemd-nspawn containers (called *jails*), including persistent volumes, users, and SSH access.
- **Private networking:** connect hosts and jails through WireGuard overlays with dynamic routing and stable IPv6 addresses. Named endpoints let services reference backends across hosts.
- **DNS and service gateways:** compose authoritative DNS, HTTP/TLS proxies, and SMTP gateways, with ACME certificates, a private certificate authority, and mutual TLS for internal connections.
- **Secrets and generated data:** encrypt secrets with age, re-encrypt them for deployment, and make them available to hosts and jails. Generators produce keys, certificates, and credentials in dependency order; public data is stored as workspace *facts*.
- **Remote deployment:** build and sign a NixOS system locally, then transfer and activate it over SSH, one host at a time. Target machines do not need to perform the build.
- **Local development:** run hosts as QEMU VMs on shared virtual networks, reusing infrastructure modules in a local environment.

Alloy integrates with Nix flakes and can be extended with your own modules. Disko and Home Manager integrations are optional.

## Examples

[`kennyzavr/infra`](https://github.com/kennyzavr/infra) is the author's infrastructure built with Alloy. It combines workstations and VPS hosts, public DNS, a private CA, and public gateways connected to services over a private overlay. It also demonstrates custom mail and Xray modules, and shared configuration for production and QEMU environments.

## Alternatives

[Clan](https://clan.lol/) addresses similar goals: managing NixOS machines, services, networking, and secrets. Consider it a more mature alternative to Alloy at this stage, with a broader collection of reusable services and [documentation](https://docs.clan.lol/) covering setup and ongoing operation.
