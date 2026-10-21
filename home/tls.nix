{
  config,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:
let
  cfg = config.jmq.tls;

  # NixOS owns trust through security.pki, so reuse its bundle there. Other
  # hosts get the same policy from a pinned Nixpkgs bundle: the macOS
  # /etc/ssl/cert.pem and distro stores can lag behind root distrusts.
  caBundle =
    if osConfig != null then
      "/etc/ssl/certs/ca-certificates.crt"
    else
      "${
        pkgs.cacert.override {
          blacklist = cfg.distrustedRoots;
          extraCertificateFiles = cfg.extraCertificateFiles;
        }
      }/etc/ssl/certs/ca-bundle.crt";
in
{
  options.jmq.tls = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Point OpenSSL, Bun, Node.js, Python, AWS CLI, gRPC, curl and Git at
        one trust store. Without this, Bun-based tools (Claude Code, OMP),
        botocore, httplib2 and gRPC use their own embedded roots and miss root
        distrusts.
      '';
    };

    distrustedRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Matches nixos/modules/security/ca.nix for CVE-2026-111943 (compromised
      # eMudhra intermediates). Drop once cacert ships NSS 3.131.1 or newer.
      default = [
        "Comodo AAA Services root"
        "emSign ECC Root CA - G3"
        "emSign Root CA - C1"
        "emSign ECC Root CA - C3"
      ];
      description = "Root CA labels removed from the non-NixOS bundle.";
    };

    extraCertificateFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ../pki/homelab-ca.crt ];
      description = "PEM roots added to the non-NixOS bundle.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.sessionVariables = {
      SSL_CERT_FILE = caBundle;
      NIX_SSL_CERT_FILE = caBundle;
      CURL_CA_BUNDLE = caBundle;
      GIT_SSL_CAINFO = caBundle;
      REQUESTS_CA_BUNDLE = caBundle;
      PIP_CERT = caBundle;
      AWS_CA_BUNDLE = caBundle;
      HTTPLIB2_CA_CERTS = caBundle;
      GRPC_DEFAULT_SSL_ROOTS_FILE_PATH = caBundle;
    };
  };
}
