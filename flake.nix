{
  description = "Homelab cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix }:
    let
      mkHost = hostname: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ 
          ./hosts/${hostname}
          sops-nix.nixosModules.sops
        ];
      };
    in {
      nixosConfigurations = {
        nix-thinkpad = mkHost "nix-thinkpad";
      };
    };
}