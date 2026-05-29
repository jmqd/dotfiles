{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jmq.yubikey;
  configuredSerial = if cfg.serial == null then "" else cfg.serial;

  longPressOnlyTool = pkgs.writeShellApplication {
    name = "yubikey-long-press-only";
    runtimeInputs = [ cfg.package ];
    text = ''
      configured_serial=${lib.escapeShellArg configuredSerial}

      ykman_device_args=()
      if [[ -n "$configured_serial" ]]; then
        ykman_device_args=(--device "$configured_serial")
      fi

      usage() {
        cat <<'EOF'
      Usage: yubikey-long-press-only [COMMAND] [OPTIONS]

      Configure the YubiKey OTP touch slots so keyboard-style OTP/static output
      only happens on long press.

      YubiKey OTP touch slots:
        slot 1 = short touch
        slot 2 = long touch

      Desired long-press-only state:
        slot 1 empty
        slot 2 configured, or both slots empty

      Commands:
        status                    Show connected keys and OTP slot state.
        apply                     Enforce long-press-only state.
        --delete-short-press-slot Delete OTP slot 1.
        --swap-slots              Swap OTP slots 1 and 2.
        -h, --help                Show this help.

      Options:
        -y, --yes                 Skip this helper's confirmation prompts.

      apply behavior:
        slot 1 empty, slot 2 empty       -> no-op
        slot 1 empty, slot 2 programmed  -> no-op
        slot 1 programmed, slot 2 empty  -> swap slots, moving credential to long press
        slot 1 programmed, slot 2 programmed -> delete slot 1

      WARNING: apply may swap or delete OTP slots. This mutates hardware state and
      can destroy the short-press credential in slot 1.
      EOF
      }

      ykman_otp_info() {
        ykman "''${ykman_device_args[@]}" otp info
      }

      show_status() {
        echo "Connected YubiKeys:"
        ykman list || true
        if [[ -n "$configured_serial" ]]; then
          echo "Configured serial: $configured_serial"
        fi
        echo
        echo "OTP slot state:"
        ykman_otp_info
      }

      require_yes_or_confirm() {
        local yes="$1"
        local prompt="$2"
        local expected="$3"
        local response=""

        if [[ "$yes" == "1" ]]; then
          return 0
        fi

        if [[ ! -t 0 ]]; then
          echo "Refusing OTP slot update without --yes or an interactive terminal." >&2
          exit 1
        fi

        echo
        read -r -p "$prompt " response
        if [[ "$response" != "$expected" ]]; then
          echo "Aborted." >&2
          exit 1
        fi
      }

      parse_yes_flag() {
        local yes=0
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -y|--yes)
              yes=1
              shift
              ;;
            *)
              echo "Unknown option: $1" >&2
              exit 2
              ;;
          esac
        done
        printf '%s\n' "$yes"
      }

      slot_state() {
        local slot="$1"
        local info="$2"
        awk -F': ' -v slot="Slot $slot" '$1 == slot { print $2 }' <<<"$info"
      }

      apply_long_press_only() {
        local yes="$1"
        local info=""
        local slot1=""
        local slot2=""

        if ! info="$(ykman_otp_info)"; then
          echo "Unable to read YubiKey OTP slot state; leaving key unchanged." >&2
          return 1
        fi

        printf '%s\n' "$info"
        slot1="$(slot_state 1 "$info")"
        slot2="$(slot_state 2 "$info")"

        case "$slot1:$slot2" in
          empty:empty)
            echo "Already long-press-only: neither touch slot is programmed."
            ;;
          empty:programmed)
            echo "Already long-press-only: short-touch slot 1 is empty; long-touch slot 2 is programmed."
            ;;
          programmed:empty)
            cat <<'EOF'

      Slot 1 is programmed and slot 2 is empty. Moving the credential from short
      touch to long touch by swapping OTP slots.
      EOF
            require_yes_or_confirm "$yes" "Type ENFORCE LONG PRESS ONLY to continue:" "ENFORCE LONG PRESS ONLY"
            ykman "''${ykman_device_args[@]}" otp swap --force
            echo "Moved OTP credential to long-touch slot 2."
            ;;
          programmed:programmed)
            cat <<'EOF'

      Both OTP slots are programmed. Deleting short-touch slot 1 so only the
      long-touch slot 2 can emit output.
      EOF
            require_yes_or_confirm "$yes" "Type DELETE SLOT 1 to continue:" "DELETE SLOT 1"
            ykman "''${ykman_device_args[@]}" otp delete --force 1
            echo "Deleted short-touch slot 1."
            ;;
          *)
            echo "Unexpected ykman otp info output; leaving key unchanged:" >&2
            printf '%s\n' "$info" >&2
            return 1
            ;;
        esac
      }

      command="''${1:-status}"
      if [[ $# -gt 0 ]]; then
        shift
      fi

      case "$command" in
        status|--status)
          show_status
          ;;
        apply|--apply)
          yes="$(parse_yes_flag "$@")"
          apply_long_press_only "$yes"
          ;;
        --delete-short-press-slot|delete-short-press-slot)
          yes="$(parse_yes_flag "$@")"
          show_status
          cat <<'EOF'

      WARNING: this deletes OTP slot 1, the short-touch slot. This is destructive.
      EOF
          require_yes_or_confirm "$yes" "Type DELETE SLOT 1 to continue:" "DELETE SLOT 1"
          exec ykman "''${ykman_device_args[@]}" otp delete --force 1
          ;;
        --swap-slots|swap-slots)
          yes="$(parse_yes_flag "$@")"
          show_status
          cat <<'EOF'

      WARNING: this swaps OTP slot 1 and slot 2. If your credential is currently
      in slot 1 and slot 2 is empty, this moves it to long touch. This mutates
      hardware state.
      EOF
          require_yes_or_confirm "$yes" "Type SWAP SLOTS to continue:" "SWAP SLOTS"
          exec ykman "''${ykman_device_args[@]}" otp swap --force
          ;;
        -h|--help|help)
          usage
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.jmq.yubikey = {
    enable = lib.mkEnableOption "YubiKey management tooling";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.yubikey-manager;
      defaultText = lib.literalExpression "pkgs.yubikey-manager";
      description = "YubiKey Manager package providing the ykman CLI.";
    };

    serial = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "12345678";
      description = ''
        Optional YubiKey serial number to target for automatic configuration.
        Leave null to let ykman select the key when exactly one key is present.
      '';
    };

    otp.longPressOnly.enforceOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Automatically enforce long-press-only OTP touch behavior during Home
        Manager activation. This may swap OTP slots or delete slot 1 on the
        physical YubiKey, so enable only for keys you intentionally manage this
        way.
      '';
    };

    otp.longPressOnly.failActivationOnError = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether Home Manager activation should fail if automatic long-press-only
        enforcement cannot inspect or update the YubiKey. When false, activation
        prints a warning and continues, which is friendlier when the key is not
        plugged in.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      cfg.package
      longPressOnlyTool
    ];

    home.activation.enforceYubikeyLongPressOnly = lib.mkIf cfg.otp.longPressOnly.enforceOnActivation (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        echo "Enforcing YubiKey OTP long-press-only configuration..."
        if ! ${longPressOnlyTool}/bin/yubikey-long-press-only apply --yes; then
          echo "warning: unable to enforce YubiKey OTP long-press-only configuration" >&2
          ${lib.optionalString cfg.otp.longPressOnly.failActivationOnError "exit 1"}
        fi
      ''
    );
  };
}
