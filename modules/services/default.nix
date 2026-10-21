{
  imports = [
    ./dns-edge.nix
    ./dns-auth.nix
    ./dns-acme.nix
    ./http-edge.nix
    ./smtp-edge.nix
    ./tls-edge.nix
    ./ca.nix
  ];

  flake.alloyModules.services = { };
}
