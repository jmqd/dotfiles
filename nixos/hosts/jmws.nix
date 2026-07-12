{
  config,
  lib,
  pkgs,
  ...
}:
let
  enableTexliveOrgPdf = false;
  vncAllowedTailnetIpv4 = [
    # jmws desktop
    "100.80.51.119"
    # Jordans-MacBook-Pro
    "100.94.227.118"
    # iphone-15
    "100.106.214.30"
  ];
  vncTailnetFirewallRules = lib.concatMapStringsSep "\n" (
    addr: "iptables -w -A tailscale-vnc -s ${addr}/32 -j ACCEPT"
  ) vncAllowedTailnetIpv4;

  texliveOrgPdf = pkgs.texlive.combine {
    # Enough for normal Org LaTeX/PDF export, latexmk workflows, and CJK
    # documents via LuaLaTeX/XeLaTeX without pulling in scheme-full's multi-GB
    # closure.
    inherit (pkgs.texlive)
      scheme-small
      latexmk
      collection-luatex
      collection-xetex
      collection-langcjk
      fontspec
      unicode-math
      xecjk
      ctex
      luatexja
      ;
  };
in
{
  imports = [
    ../hardware-configuration.nix
    ./jmws-nas.nix
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "jmws";

  time.timeZone = "Asia/Tokyo";

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 90d";
  };

  # Something required for i3.
  environment.pathsToLink = [ "/libexec" ];

  nix.settings = {
    allowed-users = [ "@wheel" ];
    trusted-users = [
      "root"
      "@wheel"
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    builders-use-substitutes = true;
    connect-timeout = 5;
    fallback = true;
  };
  nixpkgs.config = {
    allowUnfree = true;
    permittedInsecurePackages = [ "googleearth-pro-7.3.7.1155" ];
  };

  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans-static
    noto-fonts-cjk-serif-static
    noto-fonts-color-emoji
    corefonts
    jetbrains-mono
  ];

  security.pam.loginLimits = [
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "16384";
    }
  ];

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };
  networking.firewall = {
    trustedInterfaces = [ "tailscale0" ];
    extraCommands = ''
      iptables -w -D INPUT -i tailscale0 -p tcp --dport 5900 -j tailscale-vnc 2>/dev/null || true
      iptables -w -F tailscale-vnc 2>/dev/null || true
      iptables -w -X tailscale-vnc 2>/dev/null || true
      iptables -w -N tailscale-vnc
      ${vncTailnetFirewallRules}
      iptables -w -A tailscale-vnc -j DROP
      iptables -w -I INPUT 1 -i tailscale0 -p tcp --dport 5900 -j tailscale-vnc
    '';
  };
  services.timesyncd.enable = true;

  services.displayManager.defaultSession = "none+i3";
  services.xserver = {
    enable = true;
    desktopManager = {
      xterm.enable = false;
    };
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [
        dmenu
        i3status
        i3lock
        i3wsr
      ];
    };
  };

  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
      };
    };
    spiceUSBRedirection.enable = true;
  };
  services.spice-vdagentd.enable = true;

  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModulePackages = with config.boot.kernelPackages; [ v4l2loopback.out ];

  boot.extraModprobeConfig = ''
    options kvm_amd nested=1
    options kvm ignore_msrs=1
    options v4l2loopback exclusive_caps=1 card_label="Virtual Camera"
  '';

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  users.users.jmq = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "libvirtd"
      "input"
      "audio"
      "ydotool"
    ];
    shell = pkgs.zsh;
  };

  environment.systemPackages =
    (with pkgs; [
      # system admin / linux core
      doas
      lshw
      pciutils
      vim
      git
      read-edid
      nmap
      arp-scan
      fontconfig
      freetype
      expat
      mesa-demos
      ipmitool
      inetutils
      nixos-anywhere
      inxi
      openssl
      openssl.dev
      vlc
      isync
      offlineimap
      bandwhich
      lemmeknow
      terraform

      # wine and gaming deps
      gimp
      socat
      spice
      spice-gtk
      spice-protocol
      virtio-win
      win-spice
      adwaita-icon-theme
      libgudev
      libvdpau
      dxvk
      krb5
      obs-studio

      # development toolchain
      emscripten
      efibootmgr
      certbot
      gnumake42
      dig
      udev
      systemd
      gcc
      gccgo13
      bazel
      flyctl
      gdb
      poetry
      clang
      nodejs_24
      yarn
      black
      pipenv
      trunk
      vultr-cli

      libGLU
      libGL

      (python3.withPackages (
        ps: with ps; [
          openai
          requests
          boto3
          pyflakes
          black
          isort
          pipenv
          pytest
        ]
      ))
      # others
      languagetool
    ])
    ++ (if enableTexliveOrgPdf then [ texliveOrgPdf ] else [ ]);

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    gcc.cc.libgcc
    stdenv.cc.cc.lib
  ];

  programs.steam.enable = true;
  programs.dconf.enable = true;
  programs.zsh.enable = true;
  programs.ydotool.enable = true;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  system.stateVersion = "25.05";
}
