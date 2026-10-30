---
name: shell-scripts
description: House style for writing or editing shell scripts. Use before creating or changing any .sh file or script the user will run.
---

# Shell scripts

Follow the style of rustup's `rustup-init.sh`:
<https://github.com/rust-lang/rustup/blob/master/rustup-init.sh>.

## Shape

- Start with a shebang and a header comment that says what the script does,
  what it reads, and whether it changes anything.
- Put all logic in small named functions. Define helpers before use.
- End with `main "$@" || exit 1` as the last line, so a partial download or
  copy runs nothing.
- Take inputs as arguments or environment variables with documented
  defaults. Do not hard-code environments, IDs, or time windows. Print
  usage on `-h` and on missing arguments.
- Default to a read-only or dry-run mode when the script can change state.
  Require an explicit flag to mutate.

## Failure handling

- Use POSIX `sh` with `set -u`. Use bash only when the script needs arrays
  or other bash features; keep the same style.
- Do not rely on `set -e`. Make each failure path explicit:
  - `need_cmd <cmd>`: exit with a clear message when a dependency is missing.
  - `ensure <cmd...>`: run a command and exit with a clear message on failure.
  - `ignore <cmd...>`: run a command whose failure is deliberately ignored.
  - `say` for progress and `err` for errors, both on stderr.
- Check every dependency with `need_cmd` at the start of `main`.

## Hygiene

- Quote every expansion. Keep the script `shellcheck` clean.
- Do not use `rm`. Move files to the trash or another reversible location.
- Never print secrets.

## Helpers

```sh
say() { printf '%s: %s\n' "${0##*/}" "$1" >&2; }
err() { say "error: $1"; exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
need_cmd() { check_cmd "$1" || err "need '$1' (command not found)"; }
ensure() { "$@" || err "command failed: $*"; }
ignore() { "$@"; }
```
