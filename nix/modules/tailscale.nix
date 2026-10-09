{ config, ... }:
{
  sops.secrets."tailscale/authkey".sopsFile = ../secrets/tailscale.yaml;

  services.tailscale = {
    enable = true;
    openFirewall = true;
    authKeyFile = config.sops.secrets."tailscale/authkey".path;
    authKeyParameters.preauthorized = true;
    extraUpFlags = [
      "--advertise-tags=tag:vps"
    ];
  };
}
