{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "pi";
  version = "0.59.0";

  src = ./.;
  npmDepsHash = "sha256-5SGkgugMBRaxbGP/TMPrCiHM/FmVHMBWipooJeuDM4s=";
  dontNpmBuild = true;

  meta = with lib; {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = platforms.unix;
  };
}
