{
  flake.alloyModules.core =
    {
      lib,
      ...
    }:
    {
      options._internal.state = lib.mkOption {
        default = { };
        type = lib.types.functionTo (lib.types.attrsOf lib.types.anything);
        internal = true;
      };
    };
}
