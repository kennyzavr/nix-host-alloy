{
  lib,
  modulesPath ? toString ./.,
  inputs,
  alib ? import ./lib.nix {
    inherit alib lib modulesPath inputs;
  },
}:
alib
