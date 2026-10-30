# hyper — the NixOS host. Everything below is the whole hypervisor.
{ lib, pkgs, net, ... }:
{
  imports = [
    ../../modules/constants.nix
    ../../modules/keys.nix
    ./disko.nix
  ];

  networking.hostName = "hyper";
  # ZFS requires a stable 8-hex-digit host id. Any random value works; do not
  # reuse it on a second machine.
  networking.hostId = "3f2a9c14";

  time.timeZone = "UTC";

  boot.loader.systemd-boot.enable = true;
  # If the firmware refuses to write EFI variables ("cannot create EFI variable"
  # during install), set this to false and add
  #   boot.loader.efi.efiSysMountPoint = "/boot";
  #   boot.loader.grub.efiInstallAsRemovable = ... (or use systemd-boot with
  #   the removable path). Check `efibootmgr` output first.
  boot.loader.efi.canTouchEfiVariables = true;

  # SATA + USB in the initrd. Compare against the hardware-configuration.nix that
  # `nixos-generate-config` produces on the real box and keep anything it adds.
  boot.initrd.availableKernelModules = [
    "ahci"
    "nvme"
    "sd_mod"
    "sr_mod"
    "usbhid"
    "xhci_pci"
  ];

  # Uncomment whichever matches the CPU (the GTX 960 era suggests Intel, but check
  # /proc/cpuinfo):
  # hardware.cpu.intel.updateMicrocode = true;
  # hardware.cpu.amd.updateMicrocode = true;

  # Root is ext4; ZFS is here only for the array. `ark` is imported in stage 2,
  # so a broken ZFS module build can no longer stop the host from booting.
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.extraPools = [ "ark" ];
  # Inert without a ZFS root, but it is the documented value from 26.11 on and
  # silences the nixpkgs warning.
  boot.zfs.forceImportRoot = false;
  # Kernel: left at the nixpkgs default. `latestCompatibleLinuxPackages` is
  # deprecated and now just resolves to the default kernel. If a ZFS/kernel
  # mismatch ever shows up, pin explicitly:
  #   boot.kernelPackages = pkgs.linuxPackages_6_12;

  # ---------------------------------------------------------------------------
  # Network: one 802.1Q sub-interface per VLAN, one bridge per VLAN on top.
  # The scripted backend is used deliberately: networking.vlans / .bridges /
  # .interfaces all behave predictably there, and this host has static config.
  # ---------------------------------------------------------------------------
  networking = {
    useDHCP = false;
    useNetworkd = false;

    vlans = {
      vlan10 = { id = 10; interface = net.iface; };
      vlan20 = { id = 20; interface = net.iface; };
      vlan30 = { id = 30; interface = net.iface; };
      vlan40 = { id = 40; interface = net.iface; };
      vlan50 = { id = 50; interface = net.iface; };
    };

    # Host management address lives on the VLAN, not on a bridge.
    interfaces.vlan10.ipv4.addresses = [
      { inherit (net.host) address; prefixLength = net.host.prefix; }
    ];

    defaultGateway = net.gateway;
    nameservers = net.dns;

    # Bridges carry guest traffic only — no host address on these.
    bridges = {
      br20.interfaces = [ "vlan20" ];
      br30.interfaces = [ "vlan30" ];
      br40.interfaces = [ "vlan40" ];
      br50.interfaces = [ "vlan50" ];
    };

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # ---------------------------------------------------------------------------
  # Virtualization
  # ---------------------------------------------------------------------------
  virtualisation.libvirtd = {
    enable = true;
    qemu.runAsRoot = false;
    allowedBridges = [ "br20" "br30" "br40" "br50" ];
  };

  # Defines the guest domains from the XML checked into hosts/*/domain.xml.
  # `virsh define` is idempotent; the XML paths are flake paths, so Nix copies
  # them into the store and they cannot drift from git.
  systemd.services.libvirt-domains = {
    description = "Define libvirt domains from the flake";
    wantedBy = [ "multi-user.target" ];
    after = [ "libvirtd.service" ];
    requires = [ "libvirtd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.libvirt}/bin/virsh define ${./../plex/domain.xml}
      ${pkgs.libvirt}/bin/virsh autostart plex
      ${pkgs.libvirt}/bin/virsh define ${./../edge/domain.xml}
      ${pkgs.libvirt}/bin/virsh autostart edge
    '';
  };

  # ---------------------------------------------------------------------------
  # Users / access
  # ---------------------------------------------------------------------------
  users.users.jim = {
    isNormalUser = true;
    extraGroups = [ "wheel" "libvirtd" ];
    initialPassword = "changeme"; # change with `passwd` on first login
  };

  # Without this, a bare `virsh` as a normal user talks to qemu:///session, which
  # is an empty libvirt instance — the domains live in qemu:///system.
  environment.variables.LIBVIRT_DEFAULT_URI = "qemu:///system";
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ---------------------------------------------------------------------------
  # Housekeeping
  # ---------------------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
  system.autoUpgrade.enable = false; # you pick the moment

  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = false;
  zramSwap.enable = true;

  environment.systemPackages = with pkgs; [
    git
    htop
    libvirt
    qemu_kvm
    tmux
    tree
    virt-manager
    vim
  ];

  system.stateVersion = "26.05";
}
