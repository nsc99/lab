{ cluster, lib, ... }:
let
  lan = "192.168.178.0/24";
  nodes = lib.attrValues cluster.hosts;

  mediaId = 2000;
  backupId = 3000;

  exportTo = hs: opts: lib.concatMapStringsSep " " (h: "${h}(${opts})") hs;
  squashTo = id: "all_squash,anonuid=${toString id},anongid=${toString id}";
  root = "/tank";
in
{
  users.groups.media.gid = mediaId;
  users.users.media = {
    uid = mediaId;
    group = "media";
    isSystemUser = true;
  };

  users.groups.backup.gid = backupId;
  users.users.backup = {
    uid = backupId;
    group = "backup";
    isSystemUser = true;
  };

  systemd.tmpfiles.rules = [
    "d /tank/media                 0775 media media -"
    "d /tank/backups               0775 backup backup -"
  ];

  services.nfs = {
    server = {
      enable = true;
      exports = ''
        ${root}/media   ${exportTo nodes "rw,async,no_subtree_check,${squashTo mediaId}"} ${lan}(ro,no_subtree_check,all_squash)
        ${root}/k8s     ${exportTo nodes "rw,sync,no_subtree_check,no_root_squash"}
        ${root}/backups ${exportTo nodes "rw,sync,no_subtree_check,${squashTo backupId}"}
      '';
    };

    settings.nfsd = {
      vers3 = false;
      "vers4.0" = true;
      "vers4.1" = false;
      "vers4.2" = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 2049 ];

  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [
    "/tank/media"
    "/tank/k8s"
    "/tank/backups"
  ];
}
