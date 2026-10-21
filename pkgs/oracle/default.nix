# To bump: pick a release at least 7 days old, set it in package.json and
# here, then regenerate the lock so every dependency has the same cooldown:
#   NPM_CONFIG_MIN_RELEASE_AGE=7 npm install --package-lock-only --ignore-scripts
# and take npmDepsHash from the build's hash mismatch.
{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "oracle";
  version = "0.21.5";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./bin
    ];
  };
  npmDepsHash = "sha256-JyU1nloxXWNCIcNauOmnxMKywiYbCu5JbftpVkE1CtE=";
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
