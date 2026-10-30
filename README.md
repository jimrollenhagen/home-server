# homelab

NixOS host (`hyper`) running libvirt/QEMU guests. VM definitions are checked-in
domain XML. Build plan and rationale: `PLAN.md`.

    flake.nix
    modules/
      constants.nix     every address, VLAN id, NIC name, domain name
      guest.nix         shared guest config
      keys.nix          your SSH public key (replace the placeholder)
    hosts/
      hyper/            the host: disko layout, networking, libvirtd, define-oneshot
      plex/             Plex VM (VLAN 20) + domain.xml
      edge/             Caddy VM (VLAN 30) + domain.xml

Everything is driven from `modules/constants.nix`. Change an address there and rebuild.

---

## 0. Before you touch anything

Pre-flight, in order — the first two are the ones that leave you with an unreachable
box:

- [ ] **Secure Boot disabled in firmware.** systemd-boot is unsigned; the install will
      succeed and the machine will then refuse to boot.
- [ ] **VLAN 10 exists on the UDM Pro** (README §1). The host's only address after
      install is `10.10.10.10` on `vlan10`; without that network it comes up dark.
- [ ] **NIC name is really `enp3s0`.** In the installer: `ip -br link`. If it differs,
      change `iface` in `modules/constants.nix` *before* `nixos-install`.
- [ ] **Array SATA cables unplugged.**
- [ ] `ls -l /dev/disk/by-id/ | grep -v part` still matches the device in
      `hosts/hyper/disko.nix`.
- [ ] Enough RAM for 8 GB (plex) + 2 GB (edge) + the host. If the box is 16 GB, consider
      trimming `memory` in `hosts/plex/domain.xml`.


1. **Your media must exist somewhere other than `ark`.** disko wipes disks; the
   install wipes the boot SSD. Confirm you have a copy or accept the risk knowingly.
2. **Unplug the array's SATA cables** for the install. Reconnect at step 4.
3. Record the current state so you can diff it later:

       zpool status -v ark > ~/ark-status.txt
       zfs get all ark > ~/ark-props.txt
       lsblk -o NAME,SIZE,MODEL,SERIAL > ~/disks.txt

4. The boot SSD's by-id path is already set in `hosts/hyper/disko.nix`
   (`ata-Samsung_SSD_850_EVO_250GB_…`). Confirm it still matches:

       ls -l /dev/disk/by-id/ | grep -v -- '-part'

5. Put your SSH public key in `modules/keys.nix` (replaces the placeholder).

---

## 1. VLANs on the UDM Pro

Create these networks (Settings → Networks), all "Router" enabled:

| VLAN | Name | Subnet        | Notes |
|------|------|---------------|-------|
| 10   | mgmt | 10.10.10.0/24 | host 10.10.10.10 |
| 20   | apps | 10.20.0.0/24 | plex 10.20.0.20 |
| 30   | edge | 10.30.0.0/24 | caddy 10.30.0.10 |
| 40   | dev  | 10.40.0.0/24 | unused |
| 50   | iot  | 10.50.0.0/24 | unused |

On the switch port facing the server: allow **all** tagged VLANs (no native VLAN
change — the host expects a plain trunk and tags everything itself).

Firewall rules to add (UniFi → Firewall):

- WAN → `10.30.0.10` TCP 80, 443 (only if you want remote access)
- `edge` (10.30.0.0/24) → `10.20.0.20` TCP 32400
- mgmt → everything TCP 22 (for `nixos-rebuild --target-host`)
- default: block inter-VLAN NEW connections you did not list

---

## 2. Install the host

On the NixOS installer (booted in UEFI mode), with the array unplugged:

    git clone <your-repo> /tmp/homelab && cd /tmp/homelab
    nix --experimental-features 'nix-command flakes' run \
      github:nix-community/disko -- --mode destroy,format,mount hosts/hyper/disko.nix
    nixos-install --flake .#hyper --root /mnt
    reboot

`disko` destroys the device it is pointed at. Read the path twice.

If the machine's NIC is not `enp3s0`, fix `modules/constants.nix` before installing —
otherwise you will install a host with no network. Check with `ip -br link` in the
installer.

---

## 3. First boot

Log in on the console (or SSH once keys are in) as `jim` / `changeme`, then `passwd`.

    ip -br addr              # vlan10 should hold 10.10.10.10
    ping 10.10.10.1
    sudo systemctl status libvirtd
    virsh list --all         # plex + edge, shut off (defined, but no disks yet)

If VLAN traffic is wrong, `sudo bridge vlan show` and `ip -d link show vlan20` tell
you whether the tags are where you think they are.

### Where you should be after each step

| After | `virsh list --all` | `ls /dev/zvol/ark/vm` |
|---|---|---|
| §3 first boot | `plex`, `edge` — shut off | does not exist yet |
| §4 array + zvols | same two, still shut off | `plex-os`, `plex-config`, `edge-os` |
| §5 images written | same two, still shut off | same, now containing images |
| §6 start | `running` | same |

Domains are defined by the host's `libvirt-domains` oneshot from `hosts/*/domain.xml`.
Building a guest image is not part of defining a VM — it is only what makes `virsh start`
able to boot something. If the definitions are missing, `sudo systemctl status
libvirt-domains` and `journalctl -u libvirt-domains` say why.

---

## 4. Import the array

Plug the array's SATA cables back in, boot, then:

    sudo zpool import
    sudo zpool upgrade -n ark        # read it; do NOT upgrade yet
    sudo zpool import ark
    sudo zfs set mountpoint=/srv/ark ark
    sudo zfs list

`boot.zfs.extraPools = [ "ark" ]` is already set, so after the next reboot it imports
automatically. Confirm with `zpool status -x` after a reboot.

### Datasets and zvols

`ark` has one filesystem today. Inspect where the media actually lives, then:

    # if the data is at the pool root, create siblings and move (instant, same pool)
    sudo zfs create ark/media
    sudo mv /srv/ark/* /srv/ark/media/     # only if the root dataset holds the media
    sudo zfs set recordsize=1M compression=zstd atime=off xattr=sa acltype=posixacl ark/media

    # guest disks
    sudo zfs create -V 64G -s -o volblocksize=16K ark/vm/plex-os
    sudo zfs create -V 32G -s -o volblocksize=8K  ark/vm/plex-config
    sudo zfs create -V 32G -s -o volblocksize=16K ark/vm/edge-os

    sudo mkfs.ext4 -L plex-config /dev/zvol/ark/vm/plex-config

Do not `mkfs` the `-os` zvols — the guest image is written into those.

### Media permissions for the Plex VM

virtiofs is mounted read-only, and virtiofsd runs as the `qemu` user. Make the tree
readable to that user rather than relying on uid matching:

    sudo chgrp -R qemu /srv/ark/media
    sudo chmod -R g+rX /srv/ark/media

(If you would rather not group-change the library, add the `qemu` user to whatever
group already owns it — same effect.)

---

## 5. Build the guest images

    nix build .#plex-image --out-link result-plex
    nix build .#edge-image --out-link result-edge

Each produces `result-*/nixos.qcow2`. (Equivalent native invocation:
`nixos-rebuild build-image --flake .#plex --image-variant qemu`.) Write them into the zvols:

    sudo qemu-img convert -O raw result-plex/nixos.qcow2 /dev/zvol/ark/vm/plex-os
    sudo qemu-img convert -O raw result-edge/nixos.qcow2 /dev/zvol/ark/vm/edge-os

---

## 6. Start the guests

The host already has the `libvirt-domains` oneshot; either reboot or:

    sudo systemctl restart libvirt-domains
    virsh list --all
    virsh start plex
    virsh console plex      # login jim / changeme, then passwd

The image grows its root partition to fill the zvol on first boot
(`boot.growPartition` + `autoResize`), so there is nothing to do manually — just
confirm with `df -h /` that you see the full 64 GB.

Then, in the Plex VM, claim the server: browse to `http://10.20.0.20:32400/web`
from the mgmt or apps network.

### Edge VM / Caddy

1. Set your real domain in `modules/constants.nix` (`domain = "example.com"`).
2. Point `plex.<domain>` at `10.30.0.10` at DigitalOcean.
3. Forward 80/443 on the UDM Pro to `10.30.0.10` (HTTP-01 needs 80 to reach Caddy).
4. Rebuild the edge guest and the certificate is issued on first request.

For DNS-01 instead (keeps 80 closed), follow the commented block in
`hosts/edge/default.nix`; the first build prints the `vendorHash` you need.

---

## 7. Day-2

    # host
    nix flake update
    nixos-rebuild build --flake .#hyper
    sudo nixos-rebuild switch --flake .#hyper

    # a guest, from your laptop
    nixos-rebuild switch --flake .#plex --target-host jim@10.20.0.20 --use-remote-sudo

Rollback on the host: boot the previous generation in the systemd-boot menu, or
`sudo nixos-rebuild switch --rollback`.

Editing a VM's hardware: edit `hosts/<name>/domain.xml`, commit, `nixos-rebuild switch`
on the host (the oneshot redefines it), then `virsh shutdown <name> && virsh start <name>`.
If you would rather author it in virt-manager, export with `virsh dumpxml --inactive`
or you will capture runtime state.

---

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| `virsh start` fails, no useful error | virtiofs without `<memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>` |
| Guest boots, `/media` empty or EACCES | virtiofsd (as `qemu`) cannot read `/srv/ark/media`; fix group perms (§4) |
| Guest has no network | NIC name in `hosts/<name>/default.nix` is not `eth0`, or VLAN not on the trunk |
| `nixos-rebuild --target-host` refuses | key not in `modules/keys.nix`; mgmt→guest 22 blocked on the router; or "user is not trusted" (guests set `nix.settings.trusted-users = [ "jim" ]` — deploy as `jim`, not root) |
| Domain boots to GRUB rescue | image built with UEFI/systemd-boot but the domain is BIOS — guests here are BIOS only |
| `virsh list --all` shows nothing | you are on `qemu:///session`. Use `virsh -c qemu:///system`; the host sets `LIBVIRT_DEFAULT_URI` so a bare `virsh` works after a rebuild |
| Plex cannot see the library | mount is `nofail`; check `systemctl status media.mount` and `journalctl -u virtiofsd` |
