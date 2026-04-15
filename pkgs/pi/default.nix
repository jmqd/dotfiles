{
  lib,
  buildNpmPackage,
}:
buildNpmPackage rec {
  pname = "pi";
  version = "0.67.2";

  src = ./.;
  npmDepsHash = "sha256-CLOf0Jd4Wv/kfL1T//JFVADctaSsLjGN4vcFWvguItU=";
  dontNpmBuild = true;

  meta = with lib; {
    description = "Minimal terminal coding harness";
    homepage = "https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent";
    license = licenses.mit;
    mainProgram = "pi";
    platforms = platforms.unix;
  };
}
