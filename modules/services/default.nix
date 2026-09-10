{
  imports = [
    ./dns.nix
    ./dns-acme.nix
    ./dns-gateways.nix
  ];

  flake.alloyModules.services = { };
}
