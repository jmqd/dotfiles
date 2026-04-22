{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "pi";
  version = "0.68.1";

  src = ./.;
  npmDepsHash = "sha256-RQUWITj5mVrz1rUBrvjzBtt8ZFNV8kGPVKccuH24/O4=";
  dontNpmBuild = true;

  meta = with lib; {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = platforms.unix;
  };
}
