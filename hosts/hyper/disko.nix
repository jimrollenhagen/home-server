# Single 232 GB SSD, ZFS root. WIPES THE DEVICE.
#
# Set `device` to the by-id path of the boot SSD before running disko:
#     ls -l /dev/disk/by-id/ | grep -v part
#
# The array's disks must be unplugged (or the HBA disconnected) the first time
# you run this. disko destroys whatever it is pointed at.
{ ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/REPLACE-WITH-BOOT-SSD-ID";
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
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "zroot";
            };
          };
        };
      };
    };

    zpool.zroot = {
      type = "zpool";
      mode = "";
      options = {
        ashift = "12";
        cachefile = "none";
      };
      rootFsOptions = {
        compression = "zstd";
        acltype = "posixacl";
        xattr = "sa";
        atime = "off";
        "com.sun:auto-snapshot" = "false";
      };
      mountpoint = "/";
      # Snapshot the empty pool so you always have a "bare metal" state to diff
      # against.
      postCreateHook = "zfs list -t snapshot -H -o name | grep -q '^zroot@blank$' || zfs snapshot zroot@blank";

      # The pool's own root dataset is mounted at / (see `mountpoint` above).
      # Children below get `legacy` mountpoints so NixOS mounts them from
      # fileSystems with zfsutil.
      datasets = {
        "nix" = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "legacy";
        };
        "var" = {
          type = "zfs_fs";
          mountpoint = "/var";
          options.mountpoint = "legacy";
        };
        "home" = {
          type = "zfs_fs";
          mountpoint = "/home";
          options.mountpoint = "legacy";
        };
      };
    };
  };
}
