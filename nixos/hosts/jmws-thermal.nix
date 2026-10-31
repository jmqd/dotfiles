# Logs BMC (IPMI) and hwmon temperatures and fan speeds every 30 s to
# /var/log/flow-thermal, readable by every user, so `flow thermal history`
# shows VRM temperatures without sudo. Root is needed only for /dev/ipmi0;
# the sandbox below allows nothing else.
{
  pkgs,
  flowPkg,
  ...
}:
{
  systemd.services.flow-thermal = {
    description = "Log temperatures and fan speeds (flow thermal sample)";
    path = [ pkgs.ipmitool ];
    serviceConfig = {
      Type = "oneshot";
      # VRMs alarm at 105 °C on this board; 85 °C leaves room to react, and
      # the i3 bar warns 10 °C earlier.
      ExecStart = "${flowPkg}/bin/flow --automated thermal sample --limit VRM=85";
      # The log file holds the readings; the journal keeps only the alert
      # and error warnings flow prints on stderr.
      StandardOutput = "null";
      LogsDirectory = "flow-thermal";
      LogsDirectoryMode = "0755";
      UMask = "0022";
      DevicePolicy = "closed";
      DeviceAllow = [ "/dev/ipmi0 rw" ];
      CapabilityBoundingSet = [ "" ];
      NoNewPrivileges = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      SystemCallArchitectures = "native";
    };
  };

  systemd.timers.flow-thermal = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
      AccuracySec = "5s";
    };
  };
}
