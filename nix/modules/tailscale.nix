{ config, lib, ... }:
{
  sops.secrets."tailscale/authkey".sopsFile = ../secrets/tailscale.yaml;

  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  networking.firewall.enable = true;

  services.openssh.enable = lib.mkForce false;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    authKeyParameters.preauthorized = true;
    extraSetFlags = [
      "--ssh"
      "--accept-routes=false"
    ];
    extraUpFlags = [ "--advertise-tags=tag:vps" ];
  };
}
