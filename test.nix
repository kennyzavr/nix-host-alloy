let
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  f = builtins.getFlake "git+file:///home/kennyzavr/d108/nix-host-alloy";
  alloyLib = f.lib;
  alloyModule = f.alloyModules.simpleCluster;
  res = alloyLib.evalModules {
    modules = [
      alloyModule
      {
        build.spec.generators = {
          buildScripts = true;
        };
        build.spec.qemu = {
          build = true;
          buildScripts = [ "iridium" "gallium" ];
        };
      }
    ];
    checkAssertions = false;
  };
in
res.config.build.package { inherit pkgs; }
