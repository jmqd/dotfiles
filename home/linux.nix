{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.jmq.linux;

  corePerfTools = [
    "addr2line"
    "argdist"
    "bashreadline"
    "bindsnoop"
    "biolatency"
    "biosnoop"
    "biotop"
    "bitesize"
    "blkparse"
    "blktrace"
    "bpftrace"
    "btrace"
    "btfdiff"
    "btt"
    "cachestat"
    "cachetop"
    "callgrind_annotate"
    "callgrind_control"
    "cargo-bloat"
    "cargo-criterion"
    "cargo-flamegraph"
    "cargo-llvm-lines"
    "cargo-show-asm"
    "cg_annotate"
    "cpudist"
    "cpupower"
    "ethtool"
    "eu-addr2line"
    "eu-readelf"
    "eu-stack"
    "execsnoop"
    "ext4dist"
    "ext4slower"
    "filetop"
    "fio"
    "flamegraph.pl"
    "funccount"
    "funcgraph"
    "funclatency"
    "functrace"
    "gdb"
    "heaptrack"
    "heaptrack_gui"
    "heaptrack_print"
    "hwloc-info"
    "hyperfine"
    "iftop"
    "iostat"
    "iotop"
    "iosnoop"
    "iperf3"
    "iowatcher"
    "killsnoop"
    "kprobe"
    "lstopo"
    "ltrace"
    "llvm-bolt"
    "llvm-boltdiff"
    "llvm-cov"
    "llvm-dwarfdump"
    "llvm-exegesis"
    "llvm-mca"
    "llvm-objdump"
    "llvm-profdata"
    "llvm-readelf"
    "llvm-symbolizer"
    "llvm-xray"
    "memleak"
    "merge-fdata"
    "mpstat"
    "ms_print"
    "nethogs"
    "nm"
    "numactl"
    "numastat"
    "objdump"
    "offcputime"
    "offwaketime"
    "opensnoop"
    "pahole"
    "perf"
    "perf-stat-hist"
    "perf2bolt"
    "pidstat"
    "powertop"
    "pprof"
    "pprof-symbolize"
    "profile"
    "readelf"
    "reset-ftrace"
    "runqlat"
    "runqlen"
    "sadf"
    "samply"
    "sar"
    "size"
    "stackcollapse-bpftrace.pl"
    "stackcollapse-perf.pl"
    "stackcount"
    "strace"
    "stress-ng"
    "strings"
    "syscount"
    "tcpaccept"
    "tcpconnect"
    "tcpdrop"
    "tcpdump"
    "tcplife"
    "tcpretrans"
    "tcptop"
    "trace"
    "trace-cmd"
    "tpoint"
    "uprobe"
    "valgrind"
  ];

  desktopPerfTools = [
    "hotspot"
    "kcachegrind"
    "kernelshark"
    "massif-visualizer"
  ];

  x86PerfTools = [
    "msr-cpuid"
    "rdmsr"
    "turbostat"
    "wrmsr"
  ];

  coreSecurityTools = [
    "aircrack-ng"
    "amass"
    "arp-scan"
    "auditctl"
    "aureport"
    "ausearch"
    "bettercap"
    "binwalk"
    "bwrap"
    "capinfos"
    "cewl"
    "clamscan"
    "conftest"
    "cosign"
    "crane"
    "crunch"
    "dc3dd"
    "ddrescue"
    "detect-secrets"
    "dig"
    "dive"
    "dnsx"
    "dumpcap"
    "editcap"
    "exiftool"
    "feroxbuster"
    "ffuf"
    "fls"
    "foremost"
    "freshclam"
    "fsstat"
    "gau"
    "gcrane"
    "gitleaks"
    "gobuster"
    "grype"
    "hashcat"
    "hashcat-utils"
    "hexyl"
    "host"
    "httpx"
    "hydra"
    "hydra-wizard"
    "icat"
    "john"
    "katana"
    "keepass2john"
    "kube-bench"
    "kubeaudit"
    "kubescape"
    "lynis"
    "masscan"
    "mergecap"
    "mitmdump"
    "mitmproxy"
    "mitmweb"
    "mmls"
    "mtr"
    "naabu"
    "ncat"
    "nc"
    "ncrack"
    "netcat"
    "netsniff-ng"
    "ngrep"
    "nikto"
    "nmap"
    "nping"
    "nslookup"
    "nuclei"
    "oscap"
    "osqueryd"
    "osqueryi"
    "osv-scanner"
    "photorec"
    "prowler"
    "pw-inspector"
    "r2"
    "rabin2"
    "radare2"
    "rahash2"
    "randpkt"
    "rar2john"
    "rasm2"
    "rawshark"
    "rizin"
    "rustscan"
    "scapy"
    "searchsploit"
    "semgrep"
    "sherlock"
    "sharkd"
    "slsa-verifier"
    "socat"
    "sqlmap"
    "sqlmapapi"
    "ssh-audit"
    "sslscan"
    "subfinder"
    "syft"
    "termshark"
    "testdisk"
    "testssl"
    "testssl.sh"
    "text2pcap"
    "theHarvester"
    "theharvester"
    "traceroute"
    "trivy"
    "trufflehog"
    "tsk_recover"
    "tshark"
    "unshadow"
    "vol"
    "volatility3"
    "vulnix"
    "wafw00f"
    "waybackurls"
    "whatweb"
    "whois"
    "yara"
    "zizmor"
    "zip2john"
  ];

  desktopSecurityTools = [
    "cutter"
    "ghidra"
    "imhex"
    "wireshark"
  ];
in
{
  imports = [
    ./common.nix
    ./linux-desktop.nix
  ];

  options.jmq.linux = {
    desktop.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install Linux desktop packages and desktop integrations.";
    };

    heavyweightApps.enable = lib.mkOption {
      type = lib.types.bool;
      default = pkgs.stdenv.hostPlatform.isx86_64;
      description = "Install large GUI applications that dominate fresh-machine downloads.";
    };
  };

  config = {
    home.sessionVariables = {
      TERMINAL = "wezterm";
      JM_PERF_TOOLS = lib.concatStringsSep " " (
        corePerfTools
        ++ lib.optionals cfg.desktop.enable desktopPerfTools
        ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 x86PerfTools
      );
      JM_SECURITY_TOOLS = lib.concatStringsSep " " (
        coreSecurityTools ++ lib.optionals cfg.desktop.enable desktopSecurityTools
      );
    };

    home.shellAliases = {
      top = "btm";
    };

    home.packages =
      (with pkgs; [
        killall
        nixfmt
      ])
      ++ lib.optionals cfg.desktop.enable (
        with pkgs;
        [
          autorandr
          dmenu
          ksnip
          geeqie
          hotspot
          kdePackages.kcachegrind
          kdePackages.massif-visualizer
          kernelshark
          cutter
          ghidra
          imhex
          wireshark
          i3lock
          i3wsr
          pavucontrol
          pmutils
          quickemu
          xclip
          xdotool
          ydotool
          xwininfo
        ]
      )
      ++ lib.optionals (cfg.desktop.enable && cfg.heavyweightApps.enable) (
        with pkgs;
        [
          bambu-studio
          discord
          googleearth-pro
          lutris
          slack
          spotify
          virt-manager
          virt-viewer
        ]
      );

    programs = {
      chromium.enable = cfg.desktop.enable;
      google-chrome.enable = cfg.desktop.enable && pkgs.stdenv.hostPlatform.isx86_64;
      rofi.enable = cfg.desktop.enable;

      nix-index = {
        enable = true;
        enableZshIntegration = true;
      };

      i3status-rust.enable = cfg.desktop.enable;
    };
  };
}
