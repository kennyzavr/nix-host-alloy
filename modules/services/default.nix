{
  imports = [
    ./knot.nix
    ./knot-acme.nix
    ./knot-resolver.nix
    ./dnsdist.nix
    ./nginx.nix
    ./step-ca.nix
    # ./haproxy.nix
  ];

  flake.alloyModules.services = { };
}
