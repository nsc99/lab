{ ... }:

{
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.allowedTCPPorts = [
    53
    3000
  ];

  services.adguardhome.enable = true;
  services.adguardhome = {
    mutableSettings = true;
    settings = {
      http.address = "0.0.0.0:3000";
    };
  };
}
