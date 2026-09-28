{
  serverHost = "nix-letsnote1.lab"; # etcd bootstrap node, join target for new servers
  nfsHost = "nix-optiplex1";
  hosts = {
    nix-optiplex1 = "192.168.178.100";
    nix-optiplex2 = "192.168.178.101";
    nix-letsnote1 = "192.168.178.102";
    nix-letsnote2 = "192.168.178.103";
    nix-thinkpad = "192.168.178.104";
  };
  ingressIP = "192.168.178.240";
  externalDomain = "schweigert.io"; # used for cluster services using ingress
  internalDomain = "home"; # used for nix declared services
  hostDomain = "lab"; # used for hosts
}
