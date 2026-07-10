{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jmq.trueflow;
  tomlFormat = pkgs.formats.toml { };
in
{
  options.jmq.trueflow.ai = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether trueflow AI hints are enabled.";
    };

    provider = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "anthropic"
        "open_ai"
        "claude_cli"
        "codex_cli"
        "none"
      ];
      default = "codex_cli";
      description = "Trueflow AI provider.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "gpt-5.6-codex";
      description = "Trueflow AI model.";
    };

    maxContextLines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 80;
      description = "Maximum context lines for trueflow AI hints.";
    };

    cache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether trueflow should cache AI hints.";
    };
  };

  config.home.file.".trueflow.toml".source = tomlFormat.generate "trueflow.toml" {
    ai = {
      inherit (cfg.ai)
        enabled
        provider
        model
        cache
        ;
      max_context_lines = cfg.ai.maxContextLines;
    };
  };
}
