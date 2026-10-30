# Every address and VLAN id in the build lives here. Change once, applies everywhere.
#
# VLAN plan (provision these on the UDM Pro; the plan's §6.1 has the table):
#   10 mgmt   10.10.10.0/24   host .10
#   20 apps   10.20.0.0/24    plex .20
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

    host = { address = "10.10.10.10"; prefix = 24; };
    plex = { address = "10.20.0.20"; prefix = 24; };
    edge = { address = "10.30.0.10"; prefix = 24; };

    # DNS name for the reverse proxy
    domain = "rollenhagen.me";
  };
}
