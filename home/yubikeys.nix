# Shared hardware inventory; consumers explicitly select credential purposes and origins.
# Serial numbers identify devices for management; they do not prove possession.
# Add purpose-specific public credentials only after explicit enrollment.
{
  yubikey-36766394 = {
    serial = "36766394";
    model = "YubiKey 5C NFC";
    webauthn = [
      (builtins.fromJSON (builtins.readFile ./yubikeys/36766394-omp.json))
    ];
  };
}
