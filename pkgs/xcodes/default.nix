# Pinned xcodes release binary, Developer ID-signed and notarized upstream.
# nixpkgs builds xcodes from source with a Swift toolchain that its binary
# cache does not carry for darwin, so every nixpkgs bump rebuilt it locally.
#
# pins/xcodes.json holds the release zip. Bump it with `flow pin bump xcodes`.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  versionCheckHook,
}:
let
  pin = lib.importJSON ../../pins/xcodes.json;
  source =
    pin.sources.${stdenvNoCC.hostPlatform.system}
      or (throw "xcodes is unsupported on ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "xcodes";
  inherit (pin) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [ unzip ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Generic fixup would invalidate the vendor's Apple signature.
  dontFixup = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    unzip -q $src xcodes -d $out/bin
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "version";
  installCheckPhase = ''
    runHook preInstallCheck
    # Team ZU6GR6B2FY signs xcodes releases. A valid signature from anyone
    # else must fail.
    /usr/bin/codesign --verify --strict \
      -R='anchor apple generic and certificate leaf[subject.OU] = "ZU6GR6B2FY"' \
      $out/bin/xcodes
    runHook postInstallCheck
  '';

  meta = {
    description = "Install and switch between multiple versions of Xcode";
    homepage = "https://github.com/XcodesOrg/xcodes";
    downloadPage = "https://github.com/XcodesOrg/xcodes/releases/tag/${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "xcodes";
    platforms = builtins.attrNames pin.sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
