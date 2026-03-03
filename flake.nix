{
  description = "dotfiles tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        secretsLint = pkgs.writeShellApplication {
          name = "secrets-lint";
          runtimeInputs = [ pkgs.gitleaks ];
          text = ''
            set -euo pipefail
            exec gitleaks dir --redact --exit-code 1 --no-banner .
          '';
        };
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            gitleaks
            shellcheck
            shfmt
          ];
        };

        packages.secrets-lint = secretsLint;

        apps.secrets-lint = {
          type = "app";
          program = "${secretsLint}/bin/secrets-lint";
        };
      }
    );
}
