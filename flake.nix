{
  description = "homelab — NixOS hypervisor + libvirt guests";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }@inputs:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;

      # `withBoot` adds the grub target for the runtime configuration. Image
      # builds must not include it — the image module sets it, and list options
      # merge by concatenation.
      mkGuest = name: withBoot: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          ./modules/guest.nix
        ] ++ lib.optional withBoot ./modules/guest-boot.nix ++ [
          ./hosts/${name}
        ];
      };
    in
    {
      nixosConfigurations = {
        hyper = lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            disko.nixosModules.disko
            ./hosts/hyper
          ];
        };

        plex = mkGuest "plex" true;
        edge = mkGuest "edge" true;
      };

      # Guest disk images, straight from the guest's own configuration
      # (nixpkgs' native image builder — nixos-generators is deprecated).
      #   nix build .#plex-image --out-link result-plex
      # leaves the qcow2 at ./result-plex/nixos.qcow2
      packages.${system} = {
        plex-image = (mkGuest "plex" false).config.system.build.images.qemu;
        edge-image = (mkGuest "edge" false).config.system.build.images.qemu;

        # Installer ISO that comes up SSH-able with your keys (modules/installer.nix).
        #   nix build .#installer-iso --out-link result-iso
        installer-iso = (lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./modules/keys.nix
            ./modules/installer.nix
          ];
        }).config.system.build.isoImage;
      };
    };
}
