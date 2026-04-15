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
      darwinModules.default = ./default.nix;
      darwinModules.containerization = ./default.nix;

      packages.aarch64-darwin.default = pkgs.callPackage ./package.nix { };
      packages.aarch64-darwin.kernel = pkgs.callPackage ./kernel.nix { };
      packages.aarch64-darwin.uninstall = pkgs.writeShellScriptBin "nix-apple-container-uninstall" (
        builtins.readFile ./scripts/uninstall.sh
      );
    };
}
