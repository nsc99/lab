{
  cluster,
  lib,
  pkgs,
  ...
}:
let
  lan = "192.168.178.0/24";
  nodes = lib.attrValues cluster.hosts;

  mediaId = 2000;
  backupId = 3000;
  documentsId = 4000;

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

  # paperless-ngx (cluster/apps/paperless) runs as uid/gid 4000 and the export
  # squashes every write to it, so the pod never needs to chown.
  users.groups.documents.gid = documentsId;
  users.users.documents = {
    uid = documentsId;
    group = "documents";
    isSystemUser = true;
  };

  systemd.tmpfiles.rules = [
    "d /tank/media                 0775 media media -"
    "d /tank/backups               0775 backup backup -"
    "d /tank/documents             0770 documents documents -"
    "d /tank/documents/media       0770 documents documents -"
    "d /tank/documents/data        0770 documents documents -"
    "d /tank/documents/consume     0770 documents documents -"
    "d /tank/documents/export      0770 documents documents -"
    "d /tank/documents/tessdata    0770 documents documents -"
    # Japanese OCR models (tessdata 4.1.0) that the paperless image lacks, mounted
    # as single files into its tessdata dir. Copies: a /nix/store symlink does not
    # resolve over NFS. `C` copies only if the target is missing: after a tessdata
    # bump in nixpkgs, delete the files to get the new ones.
    "C /tank/documents/tessdata/jpn.traineddata      0440 documents documents - ${pkgs.tesseract5.languages.jpn}"
    "C /tank/documents/tessdata/jpn_vert.traineddata 0440 documents documents - ${pkgs.tesseract5.languages.jpn_vert}"
  ];

  services.nfs = {
    server = {
      enable = true;
      exports = ''
        ${root}/media   ${exportTo nodes "rw,async,no_subtree_check,${squashTo mediaId}"} ${lan}(ro,no_subtree_check,all_squash)
        ${root}/k8s     ${exportTo nodes "rw,sync,no_subtree_check,no_root_squash"}
        ${root}/backups ${exportTo nodes "rw,sync,no_subtree_check,${squashTo backupId}"}
        ${root}/documents ${exportTo nodes "rw,sync,no_subtree_check,${squashTo documentsId}"}
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
    "/tank/documents"
  ];
}
