#!/usr/bin/env bash
# Deploy one machine from this flake.
#
#     scripts/deploy.sh <hyper|plex|edge|agent> [switch|boot|test]
#
# Run on hyper, from a checkout, as `jim`. Targets are addressed by FQDN, read
# out of the configuration itself (`networking.fqdn`), so there is no second
# address list here to drift from modules/constants.nix.
#
# The deploy originates on the host, so `hyper` is a plain local switch and the
# guests are reached over the network — which means the UDM Pro has to allow
# 10.10.10.10 -> TCP 22 on the apps and edge VLANs. Deploying from the laptop
# used to come in over the client LAN instead and needed no such rule.
set -euo pipefail

usage() {
  echo "usage: $0 <hyper|plex|edge|agent> [switch|boot|test]" >&2
}

host=${1:-}
action=${2:-switch}

case "$host" in
  hyper | plex | edge | agent) ;;
  *) usage; exit 2 ;;
esac

case "$action" in
  switch | boot | test) ;;
  *) echo "unknown action: $action" >&2; usage; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fqdn=$(nix --extra-experimental-features 'nix-command flakes' eval --raw \
  ".#nixosConfigurations.$host.config.networking.fqdn")

# Running on hyper makes `hyper` the local case; the check also keeps the script
# honest if it is ever run from a guest.
if [ "$(hostname -s)" = "$host" ]; then
  echo "== $host ($fqdn): this machine — local $action"
  exec sudo nixos-rebuild "$action" --flake ".#$host"
fi

echo "== $host ($fqdn): $action as jim"
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
     "jim@$fqdn" true; then
  echo "cannot ssh to jim@$fqdn — check the key, DNS, and the router rule" >&2
  exit 1
fi

exec nixos-rebuild "$action" --flake ".#$host" \
  --target-host "jim@$fqdn" --use-remote-sudo
