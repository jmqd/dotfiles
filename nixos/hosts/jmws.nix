{ config, pkgs, ... }:
{
  imports = [
    ../hardware-configuration.nix
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

  nix.settings.allowed-users = [ "@wheel" ];
  nix.settings.experimental-features = "nix-command flakes";
  nixpkgs.config.allowUnfree = true;

  fonts.fonts = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-emoji
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

  services.openssh.enable = true;
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "both";
  };
  services.timesyncd.enable = true;

  services.xserver = {
    enable = true;
    desktopManager = { xterm.enable = false; };
    displayManager = { defaultSession = "none+i3"; };
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [ dmenu i3status i3lock i3wsr ];
    };
  };

  virtualisation = {
    libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
        ovmf.enable = true;
        ovmf.packages = [ pkgs.OVMFFull.fd ];
      };
    };
    spiceUSBRedirection.enable = true;
  };
  services.spice-vdagentd.enable = true;

  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModulePackages = with config.boot.kernelPackages; [ v4l2loopback.out ];

  boot.extraModprobeConfig = ''
    options kvm_intel nested=1
    options kvm_intel emulate_invalid_guest_state=0
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
    extraGroups = [ "wheel" "libvirtd" "audio" ];
    shell = pkgs.zsh;
  };

  environment.systemPackages = with pkgs; [
    # system admin / linux core
    doas
    lshw
    pciutils
    vim
    wget
    git
    git-lfs
    fd
    read-edid
    nmap
    arp-scan
    cloc
    fontconfig
    freetype
    expat
    glxinfo
    gnuplot
    ipmitool
    inetutils
    nixos-anywhere
    inxi
    openssl
    openssl.dev
    protobuf
    p7zip
    vlc
    isync
    offlineimap
    bandwhich
    bottom
    broot
    difftastic
    fd
    lemmeknow
    procs
    tealdeer
    texlive.combined.scheme-full
    terraform

    # wine and gaming deps
    quickemu
    gimp
    socat
    virt-manager
    virt-viewer
    spice
    spice-gtk
    spice-protocol
    win-virtio
    win-spice
    adwaita-icon-theme
    libgudev
    libvdpau
    libsoup
    dxvk
    krb5
    obs-studio

    # X tools for emacs everywhere
    xorg.xwininfo
    xdotool
    xclip

    # automating xrandr profile
    autorandr

    # development toolchain
    emscripten
    rustup
    efibootmgr
    certbot
    gnumake42
    cmake
    dig
    udev
    systemd
    gcc
    gccgo13
    bazel
    sqlite
    flyctl
    gdb
    poetry
    clang
    nodejs_20
    nodejs_18
    nodejs
    nodePackages.yarn
    yarn
    black
    pkg-config
    pipenv
    tree-sitter
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
    plantuml
    graphviz

    # others
    zola
    languagetool
    pavucontrol
    jq
  ];

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    gcc.cc.libgcc
    stdenv.cc.cc.lib
  ];

  programs.steam.enable = true;
  programs.dconf.enable = true;
  programs.zsh.enable = true;

  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  system.stateVersion = "25.05";
}
