{ ... }:
{
  home.file = {
    ".bashrc".source = ../.bashrc;
    ".gdbinit".source = ../.gdbinit;
    ".local/bin/hive".source = ../bin/hive;
    ".local/bin/linear".source = ../bin/linear;
    ".local/bin/link-private-data".source = ../bin/link-private-data.sh;
    ".local/bin/lint-secrets".source = ../bin/lint-secrets.sh;
    ".local/bin/setup-git-hooks".source = ../bin/setup-git-hooks.sh;
    ".sqliterc".source = ../.sqliterc;

    ".claude/CLAUDE.md".source = ./.pi/agent/AGENTS.md;
    ".claude/commands/caveman.md".source = ./.pi/agent/skills/caveman.md;
    ".codex/prompts/commit.md".source = ./codex/prompts/commit.md;
    ".pi/agent/AGENTS.md".source = ./.pi/agent/AGENTS.md;
    ".pi/agent/keybindings.json".source = ./.pi/agent/keybindings.json;
    ".pi/agent/models.json".source = ./.pi/agent/models.json;
    ".pi/agent/settings.json".source = ./.pi/agent/settings.json;
    ".pi/agent/prompts".source = ./.pi/agent/prompts;
    ".pi/agent/skills".source = ./.pi/agent/skills;
    ".pi/agent/themes".source = ./.pi/agent/themes;
    ".pi/agent/extensions".source = ./.pi/agent/extensions;
  };
}
