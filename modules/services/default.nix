{
  imports = [
    ./dns-edge.nix
    ./dns-auth.nix
    ./dns-acme.nix
    ./dns-resolver.nix
    ./http-edge.nix
    ./smtp-edge.nix
    ./tls-edge.nix
    ./postbox.nix
    ./ca.nix
    ./xhttp-proxy.nix
  ];

  flake.alloyModules.services = { };
}
