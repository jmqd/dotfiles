{ zoekt }:
zoekt.overrideAttrs {
  # Flow indexes Git repositories and serves CLI and web searches locally.
  subPackages = [
    "cmd/zoekt"
    "cmd/zoekt-git-index"
    "cmd/zoekt-webserver"
  ];
}
