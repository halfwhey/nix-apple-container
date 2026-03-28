{
  description = "Dev/CI infrastructure for nix-apple-container";

  inputs = {
    nix-apple-container.url = "path:..";
    nixpkgs.follows = "nix-apple-container/nixpkgs";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix-darwin, nix-apple-container, ... }:
    let
      pkgs = import nixpkgs {
        system = "aarch64-darwin";
        config.allowUnfree = true;
      };

      tart = pkgs.stdenvNoCC.mkDerivation {
        pname = "tart";
        version = "2.32.0";

        src = pkgs.fetchurl {
          url =
            "https://github.com/cirruslabs/tart/releases/download/2.32.0/tart.tar.gz";
          hash = "sha256-Za3BxtCu+1Xp+oL2g7uTtiVQuNwbnQom4dWrxmUA74A=";
        };
        sourceRoot = ".";

        nativeBuildInputs = [ pkgs.makeWrapper ];

        installPhase = ''
          runHook preInstall
          mkdir -p $out/bin $out/Applications
          cp -r tart.app $out/Applications/tart.app
          makeWrapper $out/Applications/tart.app/Contents/MacOS/tart $out/bin/tart
          install -Dm444 LICENSE $out/share/tart/LICENSE
          runHook postInstall
        '';

        meta = {
          description =
            "macOS and Linux VMs on Apple Silicon to use in CI and other automations";
          homepage = "https://tart.run";
          platforms = pkgs.lib.platforms.darwin;
          mainProgram = "tart";
        };
      };
    in {
      checks.aarch64-darwin = import "${nix-apple-container}/tests/eval" {
        inherit pkgs;
        darwinLib = nix-darwin.lib;
        modulePath = nix-apple-container.darwinModules.default;
      };

      darwinConfigurations.ci-integration = nix-darwin.lib.darwinSystem {
        modules = [
          nix-apple-container.darwinModules.default
          "${nix-apple-container}/tests/fixtures/test-config.nix"
        ];
      };

      darwinConfigurations.ci-disabled = nix-darwin.lib.darwinSystem {
        modules = [
          nix-apple-container.darwinModules.default
          "${nix-apple-container}/tests/fixtures/test-config-disabled.nix"
        ];
      };

      packages.aarch64-darwin.tart = tart;

      devShells.aarch64-darwin.default =
        pkgs.mkShell { packages = [ tart pkgs.packer ]; };
    };
}
