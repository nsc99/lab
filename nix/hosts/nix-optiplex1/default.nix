{ ... }:
{
  imports = [
    ../../modules/base.nix
    ../../modules/boot-systemd.nix
    ../../modules/firewall.nix
    ../../modules/headless.nix
    ../../modules/ssh.nix
    ../../modules/k3s-server.nix
    ../../modules/users/operator.nix
    ../../modules/zfs.nix
    ../../disko/tank.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-optiplex1";
  networking.hostId = "B353293D";
}
