{ ... }:
{
  imports = [
    ../../modules/base.nix
    ../../modules/boot-systemd.nix
    ../../modules/firewall.nix
    ../../modules/headless.nix
    ../../modules/ssh.nix
    ../../modules/users/operator.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-optiplex1";
}
