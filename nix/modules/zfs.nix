{ ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  services.zfs.autoScrub.enable = true; # monthly scrub
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 3;
  };
}
