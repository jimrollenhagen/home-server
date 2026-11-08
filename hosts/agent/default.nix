# agent — Hermes and the automation account. VLAN 20 (apps), 10.20.0.30
#
# This is the box that holds the agent's key and does the builds, so it is a
# normal guest plus a firewall exception: sshd is reachable from the management
# VLAN and the client LAN only (guest.nix opens 22 to everyone else).
{ lib, pkgs, net, ... }:
{
  imports = [ ../../modules/hermes-agent.nix ];

  networking.hostName = "agent";
  networking.domain = net.agent.domain;   # agent.apps.rollenhagen.me

  networking.interfaces.eth0.ipv4.addresses = [
    { inherit (net.agent) address; prefixLength = net.agent.prefix; }
  ];
  networking.defaultGateway = "10.20.0.1";

  # mkForce because guest.nix's list merges rather than replaces.
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];

  # The iptables backend's hook, and it runs before the final reject.
  #
  # NOT `extraInputRules`: that option is declared only in
  # firewall-nftables.nix, so with the default iptables backend
  # (networking.nftables.enable = false) setting it is silently ignored —
  # which on this machine, where allowedTCPPorts is empty, meant sshd was
  # unreachable from everywhere.
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport 22 -s 10.10.10.0/24 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 22 -s 192.168.1.0/24 -j nixos-fw-accept
  '';

  # The workstation for the flake. Everything else it needs is in guest.nix.
  environment.systemPackages = with pkgs; [ git nix-output-monitor openssh ];

  # Building NixOS closures needs more store than a service guest.
  nix.settings.auto-optimise-store = true;
}
