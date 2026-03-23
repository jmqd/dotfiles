{ ... }:
{
  home.file = {
    ".bashrc".source = ../.bashrc;
    ".gdbinit".source = ../.gdbinit;
    ".sqliterc".source = ../.sqliterc;

    ".pi/agent/AGENTS.md".source = ./.pi/agent/AGENTS.md;
    ".pi/agent/keybindings.json".source = ./.pi/agent/keybindings.json;
    ".pi/agent/prompts".source = ./.pi/agent/prompts;
    ".pi/agent/skills".source = ./.pi/agent/skills;
    ".pi/agent/themes".source = ./.pi/agent/themes;
    ".pi/agent/extensions".source = ./.pi/agent/extensions;
  };
}
