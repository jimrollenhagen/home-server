# Every address, VLAN id and SSH key in the build lives here. Change once, applies everywhere.
#
# VLAN plan (provision these on the UDM Pro; the plan's §6.1 has the table):
#   10 mgmt   10.10.10.0/24   host .10
#   20 apps   10.20.0.0/24    plex .20, agent .30
#   30 edge   10.30.0.0/24    caddy .10
#   40 dev    10.40.0.0/24    (unused for now)
#   50 iot    10.50.0.0/24    (unused for now)
#   60 guest  10.60.0.0/24    (unused for now)
#   70 family 10.70.0.0/24    (unused for now)
{ ... }:
{
  _module.args.net = {
    # physical NIC on the host — confirm with `ip -br link` after install
    iface = "enp3s0";

    gateway = "10.10.10.1"; # UDM Pro
    dns = [ "10.10.10.1" ];

    # Record each machine's own FQDN here: `networking.domain` + hostName gives
    # `hostname -f`, /etc/hosts and anything that asks for the FQDN.
    #   hyper → hyper.mgmt.rollenhagen.me
    #   plex  → plex.apps.rollenhagen.me
    #   agent → agent.apps.rollenhagen.me
    #   edge  → edge.rollenhagen.me
    host = { address = "10.10.10.10"; prefix = 24; domain = "mgmt.rollenhagen.me"; };
    plex = { address = "10.20.0.20"; prefix = 24; domain = "apps.rollenhagen.me"; };
    agent = { address = "10.20.0.30"; prefix = 24; domain = "apps.rollenhagen.me"; };
    edge = { address = "10.30.0.10"; prefix = 24; domain = "rollenhagen.me"; };

    # DNS name for the reverse proxy
    domain = "rollenhagen.me";

    # Human SSH keys, applied to `jim` on every machine (modules/keys.nix) and to
    # `agent` as a break-glass way in. Nix lists are whitespace-separated.
    adminKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMR+9KlMf0ZaqqM6SOUnOrVO8MheSa5YQFw71mRAC1Ty moshi"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQDbDMhsnMvXWr/T5PAthUn+plNRtJFCUNE/tffgZg9 jim@jroll-m1.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEolcehnyRcdmH5smaq+hLwGP/BdulnGhu8YVzafxKkU jim@hyper"
    ];

    # The robot's public key, generated on the agent VM after first boot
    # (PLAN-agent.md §4 step 4). Empty is the safe default: no key, no login,
    # on every machine, until the key is committed here.
    agentKeys = [ ];
  };
}
