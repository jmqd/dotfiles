# The Intel Darwin nixpkgs branch lags OrbStack releases; other systems use
# nixpkgs as is. Bump with `flow pin bump orbstack`.
{
  lib,
  stdenv,
  fetchurl,
  orbstack,
}:
let
  pin = lib.importJSON ../../pins/orbstack.json;
  source = pin.sources.${stdenv.hostPlatform.system} or null;
in
if source == null then
  orbstack
else
  orbstack.overrideAttrs {
    inherit (pin) version;
    src = fetchurl {
      inherit (source) url hash;
    };
  }
