{ zoekt }:
zoekt.overrideAttrs (old: {
  # Flow indexes Git repositories and serves CLI and web searches locally.
  subPackages = [
    "cmd/zoekt"
    "cmd/zoekt-git-index"
    "cmd/zoekt-webserver"
  ];

  # zoekt-webserver answers any Host header, so a web page could rebind its
  # own DNS name to the local listener and read search results over every
  # indexed repository. Accept only localhost and IP-literal hosts.
  patches = (old.patches or [ ]) ++ [ ./reject-foreign-host.patch ];
})
