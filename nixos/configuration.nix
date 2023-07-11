# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running `nixos-help`).

{ config, lib, pkgs, callPackage, ... }: {
  imports = [ # Include the results of the hardware scan.
    ./hardware-configuration.nix
    <home-manager/nixos>
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "jmws"; # Define your hostname.
  # Pick only one of the below networking options.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  # networking.networkmanager.enable = true;  # Easiest to use and most distros use this by default.

  # Set your time zone.
  time.timeZone = "Asia/Tokyo";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkbOptions in tty.
  # };

  # something required for i3
  environment.pathsToLink = [ "/libexec" ];

  nix.settings.allowed-users = [ "@wheel" ];
  nix.settings.experimental-features = "nix-command flakes";

  nixpkgs.config.allowUnfree = true;

  fonts.fonts = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    corefonts
    jetbrains-mono
  ];

  # Services
  services.openssh.enable = true;
  services.tailscale.enable = true;
  services.timesyncd.enable = true;

  # my services
  systemd.user.services.cloudhome = {
    description = "cloudhome";
    after = [ "network.target" ];
    unitConfig = { Type = "Simple"; };
    serviceConfig = { ExecStart = "/run/current-system/sw/bin/cloudhome"; };
    wantedBy = [ "default.target" ];
  };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    desktopManager = { xterm.enable = false; };
    displayManager = { defaultSession = "none+i3"; };
    windowManager.i3 = {
      enable = true;
      extraPackages = with pkgs; [ dmenu i3status i3lock ];
    };
  };

  # Configure keymap in X11
  # services.xserver.layout = "us";
  # services.xserver.xkbOptions = "eurosign:e,caps:escape";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # sound.enable = true;
  hardware.pulseaudio.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  users.users.jmq = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # system admin / linux core
    doas
    vim
    wget
    git
    fd
    read-edid
    ipmitool
    openssl
    isync
    offlineimap

    # wine and gaming deps
    wine
    wineWowPackages.stable
    winetricks

    # personal software
    # TODO: relocate this file somewhere better, maybe fetchFromGit?
    (import /home/jmq/src/cloudhome)

    # X tools for emacs everywhere
    xorg.xwininfo
    xdotool
    xclip

    # automating xrandr profile
    autorandr

    # development toolchain
    cargo
    rustc
    gnumake42
    cmake
    gcc
    clang
    nodejs_20
    black
    pkg-config
    pipenv
    (python3.withPackages (ps:
      with ps; [
        openai
        requests
        boto3
        pyflakes
        black
        isort
        pipenv
        pytest
      ]))
    plantuml
    graphviz

    # others
    zola
    languagetool
  ];

  programs.steam.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # nvidia
  hardware.opengl = {
    enable = true;
    driSupport = true;
    driSupport32Bit = true;
  };
  services.xserver.videoDrivers = [ "nvidia" ];

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "23.05"; # Did you read the comment?

  home-manager.useGlobalPkgs = true;
  home-manager.users.jmq = { pkgs, ... }: {
    home.stateVersion = "23.05";

    home.packages = [
      pkgs.killall
      pkgs.ripgrep
      pkgs.unzip
      pkgs.zip
      pkgs.awscli2
      pkgs.imagemagick
      pkgs.nixfmt
      pkgs.pandoc

      # shell editing tools
      pkgs.shfmt
      pkgs.shellcheck

      # Power managment utils, e.g. pm-suspend
      pkgs.pmutils

      pkgs.lutris
      pkgs.discord
    ];

    programs = {
      alacritty = { enable = true; };
      chromium = { enable = true; };
      nix-index = {
        enable = true;
        enableBashIntegration = true;
      };
      emacs = {
        enable = true;
        package = pkgs.emacs;
      };
    };

    services.emacs = {
      enable = true;
      package = pkgs.emacs;
    };
  };
}

