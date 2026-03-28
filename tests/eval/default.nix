{ pkgs, darwinLib, modulePath }:

let
  testLib = import ./lib.nix { inherit pkgs darwinLib modulePath; };
in {
  test-defaults = import ./test-defaults.nix testLib;
  test-assertions = import ./test-assertions.nix testLib;
  test-activation-scripts = import ./test-activation-scripts.nix testLib;
  test-launchd-agents = import ./test-launchd-agents.nix testLib;
  test-linux-builder = import ./test-linux-builder.nix testLib;
  test-teardown = import ./test-teardown.nix testLib;
}
