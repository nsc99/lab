let
  mkDataDisk = device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions.zfs = {
        size = "100%";
        content = {
          type = "zfs";
          pool = "tank";
        };
      };
    };
  };
in
{
  disko.devices = {
    disk = {
      hdd1 = mkDataDisk "/dev/sdb"; # 2.5" samsung
      hdd2 = mkDataDisk "/dev/sdc"; # 2.5" toshiba
      hdd3 = mkDataDisk "/dev/sdd"; # 3.5" seagate
      hdd4 = mkDataDisk "/dev/sde"; # 3.5" seagate
    };

    zpool.tank = {
      type = "zpool";
      mode = {
        topology = {
          type = "topology";
          vdev = [
            {
              mode = "mirror";
              members = [
                "hdd1"
                "hdd3"
              ];
            }
            {
              mode = "mirror";
              members = [
                "hdd2"
                "hdd4"
              ];
            }
          ];
        };
      };

      options = {
        ashift = "12";
        autotrim = "off";
      };

      rootFsOptions = {
        compression = "lz4";
        atime = "off";
        xattr = "sa";
        acltype = "posixacl";
        dnodesize = "auto";
        mountpoint = "none";
        canmount = "off";
        "com.sun:auto-snapshot" = "false";
      };

      datasets = {
        k8s = {
          type = "zfs_fs";
          mountpoint = "/tank/k8s";
          options = {
            recordsize = "64K";
            "com.sun:auto-snapshot" = "true";
            mountpoint = "legacy";
          };
        };

        media = {
          type = "zfs_fs";
          mountpoint = "/tank/media";
          options = {
            recordsize = "1M";
            mountpoint = "legacy";
          };
        };

        backups = {
          type = "zfs_fs";
          mountpoint = "/tank/backups";
          options = {
            recordsize = "1M";
            mountpoint = "legacy";
            compression = "zstd";
            "com.sun:auto-snapshot" = "true";
          };
        };

        reserved = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            canmount = "off";
            refreservation = "100G";
          };
        };
      };
    };
  };
}
