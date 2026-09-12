{
  imports = [
    ./knot.nix
    ./knot-acme.nix
    ./knot-resolver.nix
    ./dnsdist.nix
    ./nginx.nix
    ./step-ca.nix
    ./smtp-relays.nix
    ./tcp-gateways.nix
    ./postbox.nix
    # ./haproxy.nix
  ];

  flake.alloyModules.services = { };
}
