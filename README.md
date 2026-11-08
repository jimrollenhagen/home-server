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

Names to resolve (create these as A records wherever your LAN DNS lives — UDM local
DNS, or DigitalOcean if you want them externally):

| FQDN | Address | Set by |
|---|---|---|
| `hyper.mgmt.rollenhagen.me` | 10.10.10.10 | `networking.domain = net.host.domain` |
| `plex.apps.rollenhagen.me` | 10.20.0.20 | `networking.domain = net.plex.domain` |
| `edge.rollenhagen.me` | 10.30.0.10 | `networking.domain = net.edge.domain` |

The NixOS side only gives each machine its own identity (`hostname -f`, the
`127.0.1.1` line in `/etc/hosts`); name *resolution* still comes from DNS. All three
subdomains are defined in `modules/constants.nix`.

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

**Media needs no preparation.** It is shared with the VM as a directory over virtiofs,
not copied into a volume, so it stays exactly where it already is. The only requirement
is that `hosts/plex/domain.xml` points at the real path — for this machine:

    <source dir='/srv/ark/ephemeral/media/media'/>

Skip any `zfs create ark/media` / `mv`: that step existed to give the library its own
dataset, which is a nicety (dataset properties, snapshot policy), not a requirement.

Guest disks do need to exist, and the parent dataset first (`zfs create -p` also works):

    sudo zfs create ark/vm
    sudo zfs create -V 64G -s -o volblocksize=16K ark/vm/plex-os
    sudo zfs create -V 32G -s -o volblocksize=8K  ark/vm/plex-config
    sudo zfs create -V 32G -s -o volblocksize=16K ark/vm/edge-os

    sudo mkfs.ext4 -L plex-config /dev/zvol/ark/vm/plex-config

Do not `mkfs` the `-os` zvols — the guest image is written straight into those. The
`plex-config` volume is Plex's SQLite database: a real block device in the guest, which
is the whole reason it is not on `virtiofs`.

Optional, if you later want the library on its own dataset:

    sudo zfs create ark/media && sudo zfs mv /srv/ark/ephemeral/media/media ark/media

### Media permissions for the Plex VM

virtiofs is mounted read-only, and libvirt spawns `virtiofsd` as the unprivileged
QEMU user. On NixOS that is `qemu-libvirtd:qemu-libvirtd` (Debian calls it
`libvirt-qemu`; the name in most tutorials is wrong here). Check with `getent group
qemu-libvirtd`. Make the tree readable to that group rather than relying on uid
matching:

    sudo chgrp -R qemu-libvirtd /srv/ark/ephemeral/media/media
    sudo chmod -R g+rX /srv/ark/ephemeral/media/media

`chgrp`/`chmod` are metadata-only — no data is rewritten, though it does walk every
inode, so expect a pause on a large library. The lighter-touch alternative is
`sudo chmod -R o+rX <path>` (world-readable, no group change), which is fine on a
single-admin box and avoids the group chgrp entirely.

---

## 5. Build the guest images

    nix build .#plex-image --out-link result-plex
    nix build .#edge-image --out-link result-edge
    nix build .#agent-image --out-link result-agent

Each produces a directory holding one qcow2 whose name carries the nixpkgs revision
(`nixos-image-qcow2-26.11.<date>.<rev>-x86_64-linux.qcow2`), so glob it. (Equivalent native
invocation: `nixos-rebuild build-image --flake .#plex --image-variant qemu`.) Write them
into the zvols:

    sudo qemu-img convert -O raw result-plex/*.qcow2 /dev/zvol/ark/vm/plex-os
    sudo qemu-img convert -O raw result-edge/*.qcow2 /dev/zvol/ark/vm/edge-os
    sudo qemu-img convert -O raw result-agent/*.qcow2 /dev/zvol/ark/vm/agent-os

The zvols themselves are created by hand first (`zfs create -V 64G ark/vm/plex-os`, and
the same for `edge-os` at 32 G and `agent-os` at 64 G).

### 5.5 Importing an existing Plex config (optional)

Carrying a library over from the old host? Do this before the VM's first start. The
`plex-config` zvol is plain ext4, so mount it on the host and copy into it.

**1. Check the library paths.** Plex stores *absolute* paths in its database, and the VM
mounts the library at `/media`. If the old server saw a different root, every item shows
as unavailable even though the files are perfectly fine.

    sqlite3 "/path/to/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db" \
      "select root_path from section_locations;"

If those are not `/media/...`, add a bind mount in the guest rather than editing the
database — old paths keep resolving, nothing is rewritten:

    fileSystems."/data/media" = {
      device = "/media";
      fsType = "none";
      options = [ "bind" "ro" ];
    };

**2. Check the size.** The volume is 32 GB and library metadata for a big collection runs
10–40 GB. `du -sh` the old directory; if it is close, grow first:

    sudo zfs set volsize=64G ark/vm/plex-config
    sudo mount /dev/zvol/ark/vm/plex-config /mnt
    sudo resize2fs /dev/zvol/ark/vm/plex-config
    sudo umount /mnt

**3. Stop the old server.** The copy carries `MachineIdentifier` from `Preferences.xml`,
which is what you want — same server, clients keep working — but two running servers with
the same identity confuse clients.

**4. Copy, with the VM stopped:**

    sudo mkdir -p /mnt/plexconfig
    sudo mount /dev/zvol/ark/vm/plex-config /mnt/plexconfig
    sudo rsync -aHAX --info=progress2 \
      oldhost:'/path/to/Plex Media Server/' "/mnt/plexconfig/Plex Media Server/"
    sudo chown -R 193:193 "/mnt/plexconfig/Plex Media Server"
    sudo umount /mnt/plexconfig

Note the trailing slash on the source and the explicit `Plex Media Server` on the
destination. NixOS runs Plex as uid/gid **193** (`plex`) with app support dir
`/var/lib/plex`, so on the mounted volume that directory *is* `/var/lib/plex` — the
service's `PIDFile` is `${dataDir}/Plex Media Server/plexmediaserver.pid`.

Then `virsh start plex` and open `http://10.20.0.20:32400/web`: same server name,
libraries intact, watch state preserved.

**The old domain.** Nothing in the library database references it — the domain is a
connection setting, not metadata. It appears in one place, `customConnections` (the
"Custom server access URLs" field) in `Preferences.xml`, and only if the old setup
advertised a URL:

    grep -o 'customConnections="[^"]*"' "/mnt/plexconfig/Plex Media Server/Preferences.xml"

Easiest is to leave it and fix it after first boot in Settings → Network → Custom server
access URLs. While stopped, clearing it is:

    sudo sed -i 's|customConnections="[^"]*"|customConnections=""|' \
      "/mnt/plexconfig/Plex Media Server/Preferences.xml"

Leave `MachineIdentifier` and `PlexOnlineToken` alone — they are what makes this the same
server to plex.tv and to your clients. Then on first boot set Settings → Network →
Secure connections to *Preferred* (Caddy terminates TLS) and turn off Remote Access if it
still points at the old domain. Plex's own certificate is `<ip>.<hash>.plex.direct`, where
the hash comes from the machine identifier rather than your domain, so it takes care of
itself.

Two cautions. If the old install ran an older Plex, the database schema migrates forward
on first start and **does not go back** — keep the old directory until you are satisfied.
And never rsync a live database: a running Plex half-writes its SQLite files, and the
result opens fine and then quietly corrupts.

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
from the mgmt or apps network. (Skip the claim if you imported a config in §5.5 — it
arrives already claimed.)

### Edge VM / Caddy

1. `modules/constants.nix` already sets `domain = "rollenhagen.me"` — change it there if
   it should differ.
2. Point `plex.<domain>` at `10.30.0.10` at DigitalOcean.
3. Forward 80/443 on the UDM Pro to `10.30.0.10` (HTTP-01 needs 80 to reach Caddy).
4. Rebuild the edge guest and the certificate is issued on first request.

For DNS-01 instead (keeps 80 closed), follow the commented block in
`hosts/edge/default.nix`; the first build prints the `vendorHash` you need.

### Agent VM / Hermes

`agent` (10.20.0.30) is the machine that runs Hermes and holds the automation account.
It is a normal guest except for two things, both in `hosts/agent/default.nix`:

1. sshd accepts `10.10.10.0/24` and `192.168.1.0/24` only — `guest.nix` opens 22 to
   everyone, and this one uses `mkForce` to replace that.
2. It carries `git`, `nix-output-monitor` and a bigger store.
3. It runs Hermes as the `hermes-agent` systemd service, from the upstream flake's NixOS
   module (`modules/hermes-agent.nix`), as the `agent` user, with `HERMES_HOME` at
   `/home/agent/.hermes`. The configuration is `hermes/config.yaml` in this repo: the
   module installs it on every activation and refuses runtime edits, so a setting change
   is an edit, a commit, and `scripts/deploy.sh agent`.

Before first boot, on the UDM Pro:

- local DNS record `agent.apps.rollenhagen.me` → `10.20.0.30` (local resolver only);
- permit `10.20.0.30` → TCP 22 on `10.10.10.10` and `10.30.0.10`. Nothing is needed for
  plex — same bridge.

Then `virsh start agent`, `virsh console agent`, log in as `jim` / `changeme`, `passwd`,
and confirm `hostname -f` is `agent.apps.rollenhagen.me`. The rest — the agent's own key,
the sudo framework, moving Hermes — is `PLAN-agent.md` §4–§5.

Moving Hermes onto it — the key, the state copy and the cutover — is `MIGRATION.md`.

On hyper, `sudo scripts/create-agent-vm.sh` does the disk and domain steps in one go
(create the zvol, build the image, write it, define and start); it refuses to overwrite a
disk that already holds a filesystem unless `FORCE=1`.

---

## 7. Day-2

    nix flake update

    scripts/deploy.sh hyper
    scripts/deploy.sh plex
    scripts/deploy.sh edge
    scripts/deploy.sh agent

`scripts/deploy.sh <host> [switch|boot|test]` reads the target's FQDN out of the
configuration (`networking.fqdn`), builds on hyper, copies the closure and switches as
`jim`. Run it **on hyper**: hyper is then a plain local switch and the guests are reached
over the network. That path needs the UDM Pro to allow `10.10.10.10` → TCP 22 on the apps
and edge VLANs; deploying from the laptop came in over the client LAN and did not. The
script exits before building if it cannot ssh to the target.

Rollback on the host: boot the previous generation in the systemd-boot menu, or
`sudo nixos-rebuild switch --rollback`.

Editing a VM's hardware: edit `hosts/<name>/domain.xml`, commit, `nixos-rebuild switch`
on the host (the oneshot redefines it), then `virsh shutdown <name> && virsh start <name>`.
If you would rather author it in virt-manager, export with `virsh dumpxml --inactive`
or you will capture runtime state.

Every domain XML carries an explicit `<uuid>`. That is what makes `virsh define`
idempotent: without one, libvirt invents a fresh UUID on each define and refuses the
second one with `domain 'plex' already exists with uuid …`. Keep the UUID stable when you
edit the file, and never regenerate it for an existing domain.

---

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| `virsh start` fails, no useful error | virtiofs without `<memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>` |
| Guest boots, `/media` empty or EACCES | virtiofsd (as `qemu-libvirtd`) cannot read the media path in `domain.xml`; fix group perms (§4) |
| Guest has no network | NIC name in `hosts/<name>/default.nix` is not `eth0`, or VLAN not on the trunk |
| `nixos-rebuild --target-host` refuses | key not in `modules/keys.nix`; mgmt→guest 22 blocked on the router; or "user is not trusted" (guests set `nix.settings.trusted-users = [ "jim" ]` — deploy as `jim`, not root) |
| Domain boots to GRUB rescue | image built with UEFI/systemd-boot but the domain is BIOS — guests here are BIOS only |
| `libvirt-domains` fails: `domain 'plex' already exists with uuid …` | the XML has no `<uuid>`, so libvirt invents one on each define. Pin it — `virsh list --all --uuid` shows what exists |
| `virsh list --all` shows nothing | you are on `qemu:///session`. Use `virsh -c qemu:///system`; the host sets `LIBVIRT_DEFAULT_URI` so a bare `virsh` works after a rebuild |
| Plex cannot see the library | mount is `nofail`; check `systemctl status media.mount` and `journalctl -u virtiofsd` |
