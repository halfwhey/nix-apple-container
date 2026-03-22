{
  description = "nix-darwin module for Apple Containerization";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }: {
    darwinModules.default = ./default.nix;
    darwinModules.containerization = ./default.nix;

    packages.aarch64-darwin.default =
      nixpkgs.legacyPackages.aarch64-darwin.callPackage ./package.nix { };
  };
}
