{
  config,
  lib,
  pkgs,
  ...
}:
let
  postgresqlPackage = pkgs.postgresql_17;
  postgresqlMajor = lib.versions.major postgresqlPackage.version;
  stateDir = "${config.home.homeDirectory}/.local/share/postgresql";
  dataDir = "${stateDir}/${postgresqlMajor}";
  socketDir = "${stateDir}/run";
  port = 5432;

  postgresqlService = pkgs.writeShellScript "postgresql-home-service" ''
    set -eu
    umask 077

    ${pkgs.coreutils}/bin/install -d -m 0700 \
      ${lib.escapeShellArg stateDir} \
      ${lib.escapeShellArg socketDir}

    if [ ! -s ${lib.escapeShellArg "${dataDir}/PG_VERSION"} ]; then
      ${postgresqlPackage}/bin/initdb \
        --pgdata=${lib.escapeShellArg dataDir} \
        --username=${lib.escapeShellArg config.home.username} \
        --encoding=UTF8 \
        --locale=C \
        --auth-local=trust \
        --auth-host=reject \
        --no-instructions
    fi

    exec ${postgresqlPackage}/bin/postgres \
      -D ${lib.escapeShellArg dataDir} \
      -k ${lib.escapeShellArg socketDir} \
      -p ${toString port} \
      -c listen_addresses= \
      -c unix_socket_permissions=0700
  '';
in
{
  home.packages = [ postgresqlPackage ];

  # The socket directory is private to the Home Manager user. PostgreSQL does
  # not listen on TCP; clients inherit these defaults and connect locally.
  home.sessionVariables = {
    PGHOST = socketDir;
    PGPORT = toString port;
    PGUSER = config.home.username;
    PGDATABASE = "postgres";
  };

  systemd.user.services.postgresql = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    Unit = {
      Description = "Personal PostgreSQL ${postgresqlMajor} server";
      After = [ "default.target" ];
    };
    Service = {
      ExecStart = "${postgresqlService}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "default.target" ];
  };

  launchd.agents.postgresql = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ "${postgresqlService}" ];
      KeepAlive = true;
      RunAtLoad = true;
      ProcessType = "Background";
      ThrottleInterval = 5;
      StandardOutPath = "/tmp/postgresql-${config.home.username}.log";
      StandardErrorPath = "/tmp/postgresql-${config.home.username}.err.log";
    };
  };
}
