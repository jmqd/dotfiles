{ ... }:
{
  jmq.trueflow.ai = {
    provider = "claude_cli";
    model = "claude-haiku-4-5";
  };

  # Work machines do not trust the homelab CA (see bin/hm-switch.sh).
  jmq.tls.extraCertificateFiles = [ ];
}
