{
  config,
  lib,
  pkgs,
  ...
}:
let
  fakeBrew = pkgs.writeShellScriptBin "brew" ''
    echo "brew: this system is managed by Nix — install packages there instead." >&2
    exit 1
  '';
  geminiPackage = pkgs.callPackage ../../pkgs/gemini { };
  spotifyPackage = pkgs.callPackage ../../pkgs/spotify { };
  whatsappPackage = pkgs.callPackage ../../pkgs/whatsapp { };

  applications = pkgs.buildEnv {
    name = "home-manager-applications";
    paths = config.home.packages;
    pathsToLink = [ "/Applications" ];
  };

  # Stamp-based replacement for targets.darwin.copyApps. Upstream copyApps runs
  # `rsync --checksum` across every app bundle on every switch (reading/hashing
  # ~9 GB for unchanged apps). Track each bundle's resolved Nix store path in
  # XDG state and only copy changed bundles via APFS clone (with cp -R fallback).
  copyAppsScript = pkgs.writeShellApplication {
    name = "copy-home-manager-apps";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      readonly src_apps=${lib.escapeShellArg "${applications}/Applications"}
      readonly home_dir=${lib.escapeShellArg config.home.homeDirectory}
      readonly target_dir="$home_dir/Applications/Home Manager Apps"
      readonly stamp_dir="''${XDG_STATE_HOME:-$home_dir/.local/state}/home-manager/copied-apps"
      readonly dry_run="''${HM_DRY_RUN:-0}"

      shopt -s nullglob

      apps_to_copy=()
      apps_to_remove=()

      if [[ -d "$src_apps" ]]; then
        for src_entry in "$src_apps"/*.app; do
          app_name=$(basename "$src_entry")
          src_real=$(readlink -f "$src_entry")
          dst_app="$target_dir/$app_name"
          stamp_file="$stamp_dir/$app_name.stamp"
          recorded=""
          if [[ -r "$stamp_file" ]]; then
            IFS= read -r recorded < "$stamp_file" || true
          fi
          if [[ -d "$dst_app" && ! -L "$dst_app" && "$recorded" == "$src_real" ]]; then
            continue
          fi
          apps_to_copy+=("$app_name")
        done
      fi

      if [[ -d "$target_dir" && ! -L "$target_dir" ]]; then
        for existing in "$target_dir"/*.app; do
          existing_name=$(basename "$existing")
          if [[ ! -e "$src_apps/$existing_name" ]]; then
            apps_to_remove+=("$existing_name")
          fi
        done
      fi

      needs_migration=0
      if [[ -L "$target_dir" ]]; then
        needs_migration=1
      fi

      if [[ "$needs_migration" -eq 0 && ''${#apps_to_copy[@]} -eq 0 && ''${#apps_to_remove[@]} -eq 0 ]]; then
        if [[ -d "$stamp_dir" && "$dry_run" != "1" ]]; then
          for stamp_file in "$stamp_dir"/*.stamp; do
            stamp_app=$(basename "$stamp_file" .stamp)
            if [[ ! -e "$src_apps/$stamp_app" ]]; then
              rm -f "$stamp_file"
            fi
          done
        fi
        exit 0
      fi

      if [[ "$dry_run" == "1" ]]; then
        for app_name in "''${apps_to_copy[@]}"; do
          printf 'Would copy %s to %s\n' "$app_name" "$target_dir"
        done
        for app_name in "''${apps_to_remove[@]}"; do
          printf 'Would remove %s from %s\n' "$app_name" "$target_dir"
        done
        exit 0
      fi

      ensure_app_management() {
        local app_bundle
        for app_bundle in "$target_dir"/*.app; do
          if [[ -d "$app_bundle" ]]; then
            if ! /usr/bin/touch "$app_bundle/.DS_Store" >/dev/null 2>&1; then
              return 1
            fi
          fi
        done
        return 0
      }

      if [[ ! -L "$target_dir" && -d "$target_dir" ]] && ! ensure_app_management; then
        if [[ "$(/bin/launchctl managername)" != "Aqua" ]]; then
          printf >&2 'error: permission denied when trying to update apps over SSH, aborting activation\n'
          printf >&2 'Grant Full Disk Access for remote users or run home-manager in a graphical session.\n'
          exit 1
        else
          /usr/bin/tccutil reset SystemPolicyAppBundles >/dev/null 2>&1 || true
          if ! ensure_app_management; then
            printf >&2 'error: permission denied when trying to update apps, aborting activation\n'
            printf >&2 'Grant App Management permission to your terminal in System Settings > Privacy & Security > App Management.\n'
            exit 1
          fi
        fi
      fi

      echo "setting up $target_dir..." >&2
      if [[ -L "$target_dir" ]]; then
        rm -f "$target_dir"
      fi
      mkdir -p "$target_dir" "$stamp_dir"

      active_staged=""
      cleanup() {
        if [[ -n "$active_staged" && -e "$active_staged" ]]; then
          chmod -R u+w "$active_staged" 2>/dev/null || true
          rm -rf "$active_staged"
        fi
      }
      trap cleanup EXIT

      for app_name in "''${apps_to_copy[@]}"; do
        src_entry="$src_apps/$app_name"
        src_real=$(readlink -f "$src_entry")
        dst_app="$target_dir/$app_name"
        stamp_file="$stamp_dir/$app_name.stamp"
        staged="$target_dir/.$app_name.staged.$$"
        backup="$target_dir/.$app_name.old.$$"
        rm -rf "$staged" "$backup"
        active_staged="$staged"

        if ! /bin/cp -cR "$src_real" "$staged" 2>/dev/null; then
          chmod -R u+w "$staged" 2>/dev/null || true
          rm -rf "$staged"
          /bin/cp -R "$src_real" "$staged"
        fi

        # Store bundles are read-only with epoch mtime=1; macOS 26.3 rejects
        # epoch mtimes during code-signature validation.
        chmod -R u+w "$staged"
        /usr/bin/find "$staged" -exec /usr/bin/touch -h {} +

        if [[ -e "$dst_app" || -L "$dst_app" ]]; then
          mv "$dst_app" "$backup"
        fi
        if mv "$staged" "$dst_app"; then
          active_staged=""
          if [[ -e "$backup" || -L "$backup" ]]; then
            chmod -R u+w "$backup" 2>/dev/null || true
            rm -rf "$backup"
          fi
        else
          if [[ -e "$backup" || -L "$backup" ]]; then
            mv "$backup" "$dst_app" || true
          fi
          exit 1
        fi
        printf '%s\n' "$src_real" > "$stamp_file"
      done

      for app_name in "''${apps_to_remove[@]}"; do
        chmod -R u+w "''${target_dir:?}/''${app_name:?}" 2>/dev/null || true
        rm -rf "''${target_dir:?}/''${app_name:?}"
        rm -f "$stamp_dir/$app_name.stamp"
      done

      for stamp_file in "$stamp_dir"/*.stamp; do
        stamp_app=$(basename "$stamp_file" .stamp)
        if [[ ! -e "$src_apps/$stamp_app" ]]; then
          rm -f "$stamp_file"
        fi
      done
    '';
  };
in
{
  imports = [
    ../common.nix
    ./raycast.nix
    ./tailscale.nix
    ./retired-apps.nix
    ./wispr-flow.nix
    ./xcode.nix
  ];

  targets.darwin = {
    copyApps.enable = false;
    linkApps.enable = false;
  };

  home.activation.copyApps = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" ] ''
    HM_DRY_RUN="''${DRY_RUN:+1}" ${lib.getExe copyAppsScript}
  '';

  home.file."Applications/Screen Sharing.app".source =
    config.lib.file.mkOutOfStoreSymlink "/System/Applications/Utilities/Screen Sharing.app";

  # First set of macOS user packages managed by Home Manager.
  home.packages = [
    fakeBrew
    pkgs.google-cloud-sdk
    geminiPackage
    pkgs.orbstack
    spotifyPackage
    whatsappPackage
  ];
}
