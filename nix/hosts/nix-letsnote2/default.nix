{ ... }:
{
  imports = [
    ../../modules/base.nix
    ../../modules/boot-systemd.nix
    ../../modules/firewall.nix
    ../../modules/headless.nix
    ../../modules/wireless.nix
    ../../modules/ssh.nix
    ../../modules/k3s-agent.nix
    ../../modules/users/operator.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-letsnote2";
}
