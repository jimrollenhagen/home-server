# herdr — terminal runtime for coding agents (herdr.dev). One binary, no daemon,
# no config in Nix; per-user state lives in ~/.config/herdr-app. Present on every
# machine so the laptop's herdr can attach over ssh and show all panes together.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.herdr ];
}
