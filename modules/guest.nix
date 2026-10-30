# Shared config for every guest. Host-specific bits live in hosts/<name>/.
{ config, lib, pkgs, net, ... }:
{
  imports = [
    ./constants.nix
    ./keys.nix
  ];

  # Guests boot BIOS/GRUB, which matches the domain XML (no UEFI firmware).
  #
  # nixpkgs' disk-image module (used by system.build.images.qemu) sets these
  # too; keeping identical values here means one config both builds the image
  # and serves as the runtime config for `nixos-rebuild --target-host`.
  boot.loader.grub.enable = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  # Expand the root partition to fill the zvol on first boot.
  boot.growPartition = true;

  # Serial console, so `virsh console <name>` works from the host.
  boot.kernelParams = [ "console=ttyS0,115200n8" ];
  systemd.services."serial-getty@ttyS0".enable = true;

  services.qemuGuest.enable = true;

  users.users.jim = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # eth0 instead of enp1s0/ens3 — the guests address their NIC by name in
  # hosts/*/default.nix, and virtio NIC names are not worth predicting.
  networking.usePredictableInterfaceNames = false;
  networking.useDHCP = false;
  networking.nameservers = net.dns;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # root SSH is disabled above, so deployments run as jim. Pushing a closure over
  # SSH needs the receiving user to be trusted, or nix-copy-closure is refused.
  nix.settings.trusted-users = [ "jim" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
  system.autoUpgrade.enable = false;

  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [ curl htop vim ];

  system.stateVersion = "26.05";
}
