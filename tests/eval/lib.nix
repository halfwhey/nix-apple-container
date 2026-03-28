{ pkgs, darwinLib, modulePath }:

let
  lib = pkgs.lib;
in {
  inherit lib;

  # Evaluate a nix-darwin config with our module and return the config attrset
  evalDarwin = { modules ? [] }:
    (darwinLib.darwinSystem {
      modules = [
        modulePath
        {
          system.stateVersion = 5;
          nixpkgs.hostPlatform = "aarch64-darwin";
        }
      ] ++ modules;
    }).config;

  # Assert two values are equal; throws with details on failure
  assertEq = name: actual: expected:
    if actual == expected then true
    else throw "assertEq '${name}' failed:\n  expected: ${builtins.toJSON expected}\n  actual:   ${builtins.toJSON actual}";

  # Assert a string contains a substring
  assertContains = name: haystack: needle:
    if lib.hasInfix needle haystack then true
    else throw "assertContains '${name}' failed: substring not found\n  needle: ${needle}";

  # Assert a string does NOT contain a substring
  assertNotContains = name: haystack: needle:
    if !(lib.hasInfix needle haystack) then true
    else throw "assertNotContains '${name}' failed: unexpected substring found\n  needle: ${needle}";

  # Wrap a list of boolean assertions into a check derivation.
  # assert* helpers throw descriptive errors on failure.
  # Raw booleans produce a generic error if false.
  mkCheck = name: assertions:
    if builtins.all (x: x) assertions then
      pkgs.runCommand "eval-test-${name}" {} "touch $out"
    else
      throw "eval-test-${name}: one or more assertions returned false";
}
