# plex — VLAN 20 (apps), 10.20.0.20
{ config, lib, pkgs, net, ... }:
{
  networking.hostName = "plex";

  networking.interfaces.eth0.ipv4.addresses = [
    { inherit (net.plex) address; prefixLength = net.plex.prefix; }
  ];
  networking.defaultGateway = "10.20.0.1";

  # 22 from the admin network, 32400 from the edge VM (10.30.0.0/24).
  networking.firewall.allowedTCPPorts = [ 32400 ];

  # Plex is unfree; allow only that package rather than flipping the global switch.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "plexmediaserver" ];

  services.plex = {
    enable = true;
    openFirewall = false; # opened explicitly above
  };

  # Media arrives read-only over virtiofs from /srv/ark/ephemeral/media/media on the
  # host — the existing library, unchanged. Nothing is copied into a volume.
  # `nofail` + `automount` matter: a dead virtiofsd hangs the mount, and that
  # must not block boot.
  fileSystems."/media" = {
    device = "media";
    fsType = "virtiofs";
    options = [ "ro" "nofail" "x-systemd.automount" "x-systemd.idle-timeout=300" ];
  };

  # Plex's SQLite database must live on a block device, never on virtiofs.
  # Format it once on the host:
  #   mkfs.ext4 -L plex-config /dev/zvol/ark/vm/plex-config
  fileSystems."/var/lib/plex" = {
    device = "/dev/disk/by-label/plex-config";
    fsType = "ext4";
    options = [ "noatime" ];
  };
}
