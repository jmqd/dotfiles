{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "oracle";
  version = "0.18.0";

  src = ./.;
  npmDepsHash = "sha256-r5Wfih/a+qlRKkcAHuKExjTigECfCwGcQcMdOfv/Nrg=";
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
