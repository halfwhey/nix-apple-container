# Stub module that declares determinateNix options for eval testing.
# In production, the real Determinate Nix module provides these options.
{ lib, ... }: {
  options.determinateNix = {
    customSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Stub for determinateNix.customSettings.";
    };
  };
}
