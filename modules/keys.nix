# Your admin SSH key, shared by the host and every guest.
#
# Replace the placeholder below with the contents of ~/.ssh/id_ed25519.pub.
# Until you do, the only way in is the serial console (host) or VNC (guests),
# with the bootstrap password "changeme" — change it on first login:
#     passwd
{ ... }:
{
  users.users.jim.openssh.authorizedKeys.keys = [
    # TODO: replace this placeholder
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl placeholder-replace-me"
  ];
}
