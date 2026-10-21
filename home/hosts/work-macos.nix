{ lib, ... }:
{
  jmq.trueflow.ai = {
    provider = "claude_cli";
    model = "claude-haiku-4-5";
  };

  # Corporate TLS inspection CAs often live only in the keychain or in
  # /etc/ssl/cert.pem; a pinned bundle would break CLI and Nix fetches.
  jmq.tls.enable = lib.mkDefault false;
}
