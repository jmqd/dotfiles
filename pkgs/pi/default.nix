{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "pi";
  version = "0.70.0";

  src = ./.;
  npmDepsHash = "sha256-PHWWBaqhLFmdgOzjMSk11ypx5KlPOA7U7kcIKKyhRTE=";
  dontNpmBuild = true;

  meta = with lib; {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = platforms.unix;
  };
}
