{ self, ... }: {
  imports = [
    ./core
    ./services
    ./disko.nix
    ./home-manager.nix
  ];

  flake.alloyModules.default = {
    imports = [
      self.alloyModules.core
      self.alloyModules.services
    ];
  };
}
