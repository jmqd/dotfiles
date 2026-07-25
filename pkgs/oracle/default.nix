{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "oracle";
  version = "0.16.1";

  src = ./.;
  npmDepsHash = "sha256-7n6andVinLq5N16lYU518xEqt7uOZcLipI6Xf57/HK4=";
  npmDepsFetcherVersion = 2;
  dontNpmBuild = true;

  meta = with lib; {
    description = "CLI and MCP server for delegating prompts to ChatGPT";
    homepage = "https://github.com/steipete/oracle";
    license = licenses.mit;
    mainProgram = "oracle";
    platforms = platforms.unix;
  };
}
