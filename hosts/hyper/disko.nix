# Single boot SSD: ESP + plain ext4 root. WIPES THE DEVICE.
#
# Root is deliberately ext4, not ZFS:
#   - one disk means no redundancy, so ZFS snapshots are the only benefit;
#   - the host is disposable (guest data lives on `ark`) and NixOS generations
#     already give rollback of the system itself;
#   - ZFS root would put a per-kernel module in the boot path on nixos-unstable,
#     which is the one failure that takes down every guest at once.
# `ark` still uses ZFS — it is imported after switch-root, not from the initrd.
#
# The array's disks must be unplugged (or the SATA cables pulled) the first time
# you run this. disko destroys whatever it is pointed at.
{ ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/ata-Samsung_SSD_850_EVO_250GB_S21NNSAG113871V";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
              mountOptions = [ "noatime" ];
            };
          };
        };
      };
    };
  };
}
