# Custom installer ISO: the stock NixOS minimal installer, but it comes up with
# sshd running and your admin keys installed, so the machine can be driven over
# SSH instead of a physical keyboard.
#
# Build:  nix build .#installer-iso --out-link result-iso
#         dd if=$(readlink -f result-iso)/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
#
# Root SSH is deliberate here — it is an installer, and nixos-anywhere wants a
# root login (or passwordless sudo) on the target. The installed system does not
# inherit this file.
{ adminKeys, ... }:
{
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
  };

  # Same key list as the admin user (modules/keys.nix exposes it as `adminKeys`).
  users.users.root.openssh.authorizedKeys.keys = adminKeys;

  # Importing keys.nix for that list also creates `jim`; give them a group so the
  # installer evaluates (the real systems set isNormalUser themselves).
  users.users.jim.isNormalUser = true;

  networking.firewall.enable = false;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
