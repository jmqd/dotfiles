{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "pi";
  version = "0.65.2";

  src = ./.;
  npmDepsHash = "sha256-SYSIfn9BXViFtLlNRihpeNtHFFzlhjSdOKLck56Wqes=";
  dontNpmBuild = true;

  meta = with lib; {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = platforms.unix;
  };
}
