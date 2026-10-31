# edge — Caddy reverse proxy. VLAN 30, 10.30.0.10
{ config, lib, pkgs, net, ... }:
let
  inherit (net) domain;
in
{
  networking.hostName = "edge";
  networking.domain = net.edge.domain;   # edge.rollenhagen.me

  networking.interfaces.eth0.ipv4.addresses = [
    { inherit (net.edge) address; prefixLength = net.edge.prefix; }
  ];
  networking.defaultGateway = "10.30.0.1";

  # 80/443 are what the router forwards; 22 for admin.
  networking.firewall.allowedTCPPorts = [ 80 443 22 ];

  services.caddy = {
    enable = true;
    globalConfig = ''
      email admin@${domain}
    '';
    virtualHosts."plex.${domain}".extraConfig = ''
      reverse_proxy 10.20.0.20:32400
    '';
  };

  # ---------------------------------------------------------------------------
  # DNS-01 instead of HTTP-01 (keeps port 80 closed to the internet):
  #
  # The DigitalOcean DNS module is not in the stock Caddy build, so this needs a
  # rebuilt package. Uncomment and let the first build fail — Nix prints the
  # correct vendorHash, paste it in, rebuild.
  #
  #   services.caddy.package = pkgs.caddy.withPlugins {
  #     plugins = [ "github.com/caddy-dns/digitalocean@v0.0.0-20241011154643-e4a1a1b1a3b1" ];
  #     hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  #   };
  #
  # and add to the virtualHost block:
  #
  #   tls {
  #     dns digitalocean {env.DO_AUTH_TOKEN}
  #   }
  #
  # with the token supplied via environmentFile = "/run/secrets/caddy.env".
  # ---------------------------------------------------------------------------
}