# Admin SSH keys live in `net.adminKeys` (modules/constants.nix) so the `agent`
# account can share them. This module applies them to the human account.
#
# Until a key here works, the only way in is the serial console (host) or VNC
# (guests), with the bootstrap password "changeme":
#     passwd
{ net, ... }:
{
  users.users.jim.openssh.authorizedKeys.keys = net.adminKeys;
}
