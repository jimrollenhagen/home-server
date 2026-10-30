# Bootloader target for a *running* guest.
#
# Deliberately NOT part of modules/guest.nix: nixpkgs' disk-image module sets
# `boot.loader.grub.devices` to the same value when building the image, and lists
# merge by concatenation — defining it in both places produces the assertion
# "You cannot have duplicated devices in mirroredBoots".
#
# So: image builds get the device from the image module, and the runtime
# configuration (for `nixos-rebuild --target-host`) gets it from here.
{ lib, ... }:
{
  boot.loader.grub.devices = lib.mkDefault [ "/dev/vda" ];
}
