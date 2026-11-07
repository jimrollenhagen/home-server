#!/usr/bin/env bash
# Create the agent VM's disk and start the domain. Run on hyper, from the flake
# checkout, as root:
#
#     sudo scripts/create-agent-vm.sh
#
# Safe to re-run: the zvol is left alone once it holds a filesystem, and
# `virsh define` is idempotent because the domain XML pins a UUID. FORCE=1
# reimages, destroying the VM's disk.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "run me with sudo (zfs, qemu-img and virsh all need root)" >&2
  exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

zvol=${ZVOL:-ark/vm/agent-os}
size=${SIZE:-64G}
image=/tmp/agent-image

if ! zfs list "$zvol" >/dev/null 2>&1; then
  echo "creating $zvol ($size)"
  zfs create -V "$size" "$zvol"
fi

if [ "${FORCE:-0}" != 1 ] && blkid "/dev/zvol/$zvol" >/dev/null 2>&1; then
  echo "$zvol already holds a filesystem; not overwriting (FORCE=1 to reimage)" >&2
  exit 1
fi

echo "building the image"
nix build .#agent-image --out-link "$image"

echo "writing it to /dev/zvol/$zvol"
qemu-img convert -O raw "$image/nixos.qcow2" "/dev/zvol/$zvol"

systemctl restart libvirt-domains
virsh start agent || true

cat <<'EOF'

agent is defined. First boot:

    virsh console agent        # login jim / changeme, then `passwd`

then check `hostname -f` (agent.apps.rollenhagen.me) and `ip -br addr`
(10.20.0.30). PLAN-agent.md §4 continues from there.
EOF
