{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "oracle";
  version = "0.16.1";

  src = ./.;
  npmDepsHash = "sha256-MRzQPZWKXQsQnlrAwlYw5iXkHFvodvs6WKE95RQSkyo=";
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
