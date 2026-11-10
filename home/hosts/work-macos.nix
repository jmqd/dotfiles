{ lib, ... }:
{
  # Corporate TLS inspection CAs often live only in the keychain or in
  # /etc/ssl/cert.pem; a pinned bundle would break CLI and Nix fetches.
  jmq.tls.enable = lib.mkDefault false;

  # This profile inherits the personal Mac's publicUrl, whose hostname and
  # WebAuthn origin never match here, so nobody could sign in.
  services.omp-phone.enable = false;
}
