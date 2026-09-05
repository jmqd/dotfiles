{ lib, pkgs, ... }:
let
  writingStyle = import ./writing-style.nix;
  renderInstructions = source: pkgs.replaceVars source { inherit writingStyle; };
  agentInstructions = renderInstructions ./.pi/agent/AGENTS.md.in;
  promptRoot = ./.pi/agent/prompts;
  agentPrompts = pkgs.linkFarm "agent-prompts" (
    map (source: {
      # Use evaluation paths on both sides; path interpolation would copy the root to the store.
      name = lib.removeSuffix ".in" (lib.removePrefix "${toString promptRoot}/" (toString source));
      path = if lib.hasSuffix ".in" (toString source) then renderInstructions source else source;
    }) (lib.filesystem.listFilesRecursive promptRoot)
  );
in
{
  home.file = {
    ".bashrc".source = ../.bashrc;
    ".gdbinit".source = ../.gdbinit;
    ".local/bin/linear".source = ../bin/linear;
    ".local/bin/link-private-data".source = ../bin/link-private-data.sh;
    ".local/bin/lint-secrets".source = ../bin/lint-secrets.sh;
    ".local/bin/setup-git-hooks".source = ../bin/setup-git-hooks.sh;
    ".sqliterc".source = ../.sqliterc;

    ".claude/CLAUDE.md".source = agentInstructions;
    ".claude/commands/caveman.md".source = ./.pi/agent/skills/caveman.md;
    ".codex/AGENTS.md".source = agentInstructions;
    ".codex/config.toml".source = ./codex/config.toml;
    ".codex/prompts/commit.md".source = "${agentPrompts}/commit.md";
    ".codex/prompts/oracle.md".source = ./codex/prompts/oracle.md;
    ".omp/agent/AGENTS.md".source = agentInstructions;
    ".omp/agent/PERSONALITY.md".text = "${writingStyle}\n";
    ".omp/agent/config.yml".source = ./.omp/agent/config.yml;
    ".omp/agent/extensions".source = ./.pi/agent/extensions;
    ".omp/agent/extensions".recursive = true;
    ".pi/agent/AGENTS.md".source = agentInstructions;
    ".pi/agent/keybindings.json".source = ./.pi/agent/keybindings.json;
    ".pi/agent/models.json".source = ./.pi/agent/models.json;
    ".pi/agent/settings.json".source = ./.pi/agent/settings.json;
    ".pi/agent/prompts".source = agentPrompts;
    ".pi/agent/skills".source = ./.pi/agent/skills;
    ".pi/agent/themes".source = ./.pi/agent/themes;
    ".pi/agent/extensions".source = ./.pi/agent/extensions;
  };
}
