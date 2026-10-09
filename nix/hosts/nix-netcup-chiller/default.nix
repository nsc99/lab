{ lib, ... }:
{
  imports = [
    ../../modules/base.nix
    ../../modules/boot-systemd.nix
    ../../modules/headless.nix
    ../../modules/ssh.nix
    ../../modules/tailscale.nix
    ../../modules/edge-relay.nix
    ../../modules/users/operator.nix
    ../../disko/netcup-vps.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "nix-netcup-chiller";

  networking.useDHCP = false;
  networking.useNetworkd = true;
  systemd.network.networks."10-wan" = {
    matchConfig.Name = "en*"; # or the exact name from `ip a`, e.g. ens3
    networkConfig.DHCP = "ipv4";
    address = [ "2a03:4000:XXXX:XXXX::1/64" ];
    routes = [ { Gateway = "fe80::1"; } ];
  };

  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
}
