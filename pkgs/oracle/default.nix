{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "oracle";
  version = "0.21.4";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./bin
    ];
  };
  npmDepsHash = "sha256-tcciLMKJnAh8wun6gAJPIF8aMwctR7sLDmNeuInOfCM=";
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
