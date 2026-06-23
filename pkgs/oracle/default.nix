{
  lib,
  nodejs,
  nodejs_24 ? nodejs,
  symlinkJoin,
  writeShellApplication,
}:
let
  version = "0.15.0";
  nodePackage = nodejs_24;

  oracleCli = writeShellApplication {
    name = "oracle";
    runtimeInputs = [ nodePackage ];
    text = ''
      exec npx -y @steipete/oracle@${version} "$@"
    '';
  };

  oracleMcp = writeShellApplication {
    name = "oracle-mcp";
    runtimeInputs = [ nodePackage ];
    text = ''
      exec npx -y @steipete/oracle@${version} oracle-mcp "$@"
    '';
  };
in
symlinkJoin {
  name = "oracle-${version}";
  paths = [
    oracleCli
    oracleMcp
  ];

  meta = with lib; {
    description = "Pinned wrappers for the Oracle CLI and MCP server";
    homepage = "https://github.com/steipete/oracle";
    license = licenses.mit;
    mainProgram = "oracle";
    platforms = platforms.unix;
  };
}
