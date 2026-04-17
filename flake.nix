{
  description = "nix-darwin module for Apple Containerization";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.aarch64-darwin;
    in
    {
      darwinModules.default = ./module;
      darwinModules.containerization = ./module;

      packages.aarch64-darwin.default = pkgs.callPackage ./pkgs/package.nix { };
      packages.aarch64-darwin.kernel = pkgs.callPackage ./pkgs/kernel.nix { };
      packages.aarch64-darwin.uninstall = pkgs.writeShellScriptBin "nix-apple-container-uninstall" (
        builtins.readFile ./scripts/uninstall.sh
      );
    };
}
