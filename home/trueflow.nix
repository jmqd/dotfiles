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
    mode = lib.mkOption {
      type = lib.types.enum [
        "off"
        "review_plan"
        "block_hints"
        "review_plan_and_block_hints"
      ];
      default = "review_plan";
      description = "Trueflow AI review mode.";
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
      default = "gpt-5.6-sol";
      description = "Trueflow AI model.";
    };

    maxContextLines = lib.mkOption {
      type = lib.types.ints.positive;
      default = 80;
      description = "Maximum context lines for AI review briefings and block hints.";
    };

    cache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether trueflow should cache per-block AI hint responses.";
    };
  };

  config.home.file.".trueflow.toml".source = tomlFormat.generate "trueflow.toml" {
    ai = {
      inherit (cfg.ai)
        mode
        provider
        model
        cache
        ;
      max_context_lines = cfg.ai.maxContextLines;
    };
  };
}
