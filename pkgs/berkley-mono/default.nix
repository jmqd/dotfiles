{ lib, runCommandLocal, openssl, unzip }:
let
  passphraseWords = [
    "axiom"
    "candor"
    "vestige"
    "meridian"
  ];
  passphrase = lib.concatStringsSep "-" passphraseWords;
in
runCommandLocal "berkley-mono-20260328" {
  nativeBuildInputs = [
    openssl
    unzip
  ];

  preferLocalBuild = true;
  allowSubstitutes = false;

  meta = with lib; {
    description = "Berkeley Mono fonts unpacked from an obfuscated local blob";
    license = licenses.unfree;
    platforms = platforms.unix;
  };
} ''
  export BERKLEY_MONO_PASSPHRASE=${lib.escapeShellArg passphrase}

  archive="$TMPDIR/berkley-mono.zip"
  unpack_dir="$TMPDIR/berkley-mono-unpacked"
  font_dir="$out/share/fonts/opentype/berkley-mono"

  mkdir -p "$unpack_dir" "$font_dir"

  openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 \
    -in ${../../blobs/berkley-mono.zip.enc} \
    -out "$archive" \
    -pass env:BERKLEY_MONO_PASSPHRASE

  unzip -qq "$archive" -d "$unpack_dir"

  find "$unpack_dir" -type f \( -name '*.otf' -o -name '*.ttf' \) -exec cp '{}' "$font_dir/" ';'

  if ! find "$font_dir" -mindepth 1 -maxdepth 1 -type f | grep -q .; then
    echo "No font files found in decrypted Berkley Mono archive." >&2
    exit 1
  fi
''
