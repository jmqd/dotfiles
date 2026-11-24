{ zoekt }:
zoekt.overrideAttrs (old: {
  # Flow indexes Git repositories and serves CLI and web searches locally.
  subPackages = [
    "cmd/zoekt"
    "cmd/zoekt-git-index"
    "cmd/zoekt-webserver"
  ];

  # None of the three cmd/* subPackages have test files, so go test spends
  # ~40s compiling dependencies only to report [no test files].
  doCheck = false;

  # zoekt-webserver answers any Host header, so a web page could rebind its
  # own DNS name to the local listener and read search results over every
  # indexed repository. Accept only localhost and IP-literal hosts.
  patches = (old.patches or [ ]) ++ [ ./reject-foreign-host.patch ];
})
