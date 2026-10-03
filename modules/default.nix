{ self, ... }: {
  imports = [
    ./core
    ./services
  ];

  flake.alloyModules.default = {
    imports = [
      self.alloyModules.core
      self.alloyModules.services
    ];
  };
}
