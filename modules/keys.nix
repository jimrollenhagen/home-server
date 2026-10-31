# Admin SSH keys, shared by the host and every guest.
#
# Nix lists are whitespace-separated — no commas between entries.
# Until a key here works, the only way in is the serial console (host) or VNC
# (guests), with the bootstrap password "changeme":
#     passwd
{ ... }:
{
  users.users.jim.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMR+9KlMf0ZaqqM6SOUnOrVO8MheSa5YQFw71mRAC1Ty moshi"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEQDbDMhsnMvXWr/T5PAthUn+plNRtJFCUNE/tffgZg9 jim@jroll-m1.local"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEolcehnyRcdmH5smaq+hLwGP/BdulnGhu8YVzafxKkU jim@hyper"
  ];
}

