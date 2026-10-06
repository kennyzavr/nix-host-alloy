{ self, ... }: {
  imports = [
    ./core
    ./services
    ./disko.nix
  ];

  flake.alloyModules.default = {
    imports = [
      self.alloyModules.core
      self.alloyModules.services
    ];
  };
}
