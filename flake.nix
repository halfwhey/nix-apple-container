{
  description = "nix-darwin module for Apple Containerization";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    darwinModules.default = { ... }: {
      imports = [ ./default.nix ];
      _module.args.nix2containerLib =
        if inputs ? nix2container then
          inputs.nix2container.packages.aarch64-darwin
        else
          null;
    };
    darwinModules.containerization = self.darwinModules.default;

    packages.aarch64-darwin.default =
      nixpkgs.legacyPackages.aarch64-darwin.callPackage ./package.nix { };
    packages.aarch64-darwin.kernel =
      nixpkgs.legacyPackages.aarch64-darwin.callPackage ./kernel.nix { };
  };
}
