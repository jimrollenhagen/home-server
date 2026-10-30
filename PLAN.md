# Home server build — PLAN v2 (NixOS host + libvirt/QEMU, T2)

Supersedes v1, which is kept as `PLAN-v1-archive.md`. v1 explored Proxmox, rolling-host
distros and NixOS+Incus; all settled. The build is: **NixOS host, plain QEMU/KVM under
libvirt, VM definitions as checked-in domain XML.** No Proxmox, no management daemon
beyond libvirt, no VM backups.

Read §2 for what I need from you, and §13 for the pitfalls that will otherwise cost you
an evening each.

---

## 1. What we are building

```
                enp3s0 (802.1Q trunk from the UDM Pro)
                   │
     ┌─────────────┼──────────────┬───────────────┐
  vlan10        vlan20         vlan30          vlan40/50
  (mgmt)        (apps)         (edge)          (dev/iot)
     │             │              │               │
10.10.10.10      br20           br30          br40, br50
                   │              │               │
               ┌───┴───┐     ┌────┴────┐     ┌────┴────┐
               │  VMs  │     │  plex   │     │  edge   │
               │ later │     │ .0.20   │     │  caddy  │
               └───────┘     └────┬────┘     └────┬────┘
                                  │               │
                           virtiofs /media     reverse proxy
                           (ro, from /srv/ark/media)
```

- **Host**: NixOS unstable, pinned in `flake.lock`, ext4 root, no desktop. Its entire
  hypervisor surface is `virtualisation.libvirtd` plus a few bridges.
- **VMs**: NixOS guests built from the same flake, one service per VM, each on the VLAN
  it belongs to.
- **Storage**: the existing ZFS array imported once on the host. Guests get a zvol for
  their OS disk, virtiofs for read-only data, a zvol for anything with a database.
- **Updates**: `nix flake update` → build → switch → new generation. Bad generation:
  boot the previous one. True for the hypervisor layer too, which is the point.
- **Not doing**: VM backups, HA, clustering, a web UI that needs securing.

---

## 2. What I need from you before any config is written

1. **NICs** — count, speed, and device names (`eno1`? `enp4s0`?).

There's a single NIC, it's currently named enp3s0 on the current fedora install, but I imagine nixos might change this? I don't have a strong opinion on the name for the NIC. It's 1 Gbps.

2. **Switch model** — and confirmation the port facing the server is an 802.1Q trunk.

Using a Unifi UDM pro. The port is configured to allow tagged vlan traffic.

3. **VLAN IDs and subnets** — the table in §6 is invented; replace it with yours.

I updated the plan in 6.1, but haven't yet provisioned this on the router.

4. **Who routes between VLANs** — existing router/firewall, or a router VM on this box?
   Changes §6 and adds a VM.

Existing router

5. **ZFS array** — pool name, `ashift`, encryption, and **how the disks attach**. HBA
   strongly preferred; a RAID card hides disks from ZFS and breaks scrub/SMART.

- pool name: ark. it's a single pool with a single fs, no volumes.
- Disks are attached via sata.
- `zpool get ashift` gives me 0; `zdb -C | grep ashift` gives me 12
- no encryption

6. **Boot disks** — one or two NVMe/SSD for the root filesystem.

I have a single SSD boot disk. Current partition scheme is:
sde               8:64   0 232.9G  0 disk
├─sde1            8:65   0   200M  0 part /boot/efi
├─sde2            8:66   0     1G  0 part /boot
└─sde3            8:67   0 231.7G  0 part
  └─fedora-root 253:0    0 231.7G  0 lvm  /

7. **GPU** — iGPU/dGPU for Plex transcoding? Decides VM vs container in §8.2.

I have a dedicated GPU, according to lshw it is GM206 [GeForce GTX 960]

8. **Domain + DNS provider** — for ACME. Cloudflare? Internal only?

I keep my DNS at digitalocean which has worked fine with acme in the past

9. **Guest firmware** — BIOS/GRUB (simplest) or UEFI/systemd-boot. Pick one and stay
   consistent; mixing them is a common self-inflicted wound.

I don't know if I care, I guess the former is fine.

---

## 3. Host: NixOS base

### 3.1 Layout

| Piece | Choice |
|---|---|
| Channel | `nixos-unstable`, pinned via `flake.lock`, bumped deliberately |
| Root | plain ext4 on the single 250 GB SSD, declared with disko |
| Array | `ark`, imported at boot by ZFS (`boot.zfs.extraPools`) — the only ZFS here |
| Bootloader | systemd-boot on the ESP (UEFI) |
| Kernel | nixpkgs default (no explicit pin; see the note below) |
| Swap | zram; no swapfile |
| Desktop | none |

**Why ext4 and not ZFS for the root.** The root is one disk, so ZFS would buy no
redundancy — only snapshots, which NixOS generations already provide for the system
itself. Against that, a ZFS root puts a per-kernel module in the boot path, and on
nixos-unstable a kernel that outruns ZFS support is the one failure mode that takes
down every guest at once. The array keeps ZFS because that is where the data and the
snapshots matter; it is imported in stage 2, so the host still boots if ZFS does not.

disko declares the disk layout, so the host is reproducible from the repo rather than
from a memory of what you clicked in an installer. **Danger:** `disko --mode
destroy,format,mount` wipes whatever it is pointed at. Point it at the one SSD, and run
it with the array physically disconnected the first time. There is no redundancy on the
boot disk and none is intended: guest data lives on `ark`, and the host is rebuildable.

Host skeleton (sketch, not the final config):

```nix
{
  networking.hostId = "deadbeef";              # required while ZFS is enabled
  boot.supportedFilesystems = [ "zfs" ];       # for `ark`, not for the root
  boot.zfs.extraPools = [ "ark" ];             # imports the array in stage 2

  services.openssh.enable = true;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc.automatic = true;
  nix.optimise.automatic = true;
  system.autoUpgrade.enable = false;           # deliberate: you choose the moment
  system.stateVersion = "25.11";
}
```

`boot.zfs.extraPools` is the NixOS-native way to import a second pool at boot — no
`systemctl enable zfs-import-cache` juggling, and it survives rebuilds because it lives
in the config instead of in `/etc`.

### 3.2 Install order

1. Boot the installer, `git clone` the repo (or copy from USB).
2. `nixos-generate-config --no-filesystems` for hardware detection; let disko own the
   filesystem stanza.
3. `disko --mode destroy,format,mount` against the boot SSD only.
4. `nixos-install --flake .#hyper`, reboot.
5. Only now attach/power the array disks (§4).

---

## 4. Storage: importing the existing array

```bash
zpool import                       # should list ark, and nothing else
zpool upgrade -n ark               # read this output before anything else
zpool import ark
zfs set mountpoint=/srv/ark ark
```

`ark` holds one filesystem and no volumes, so this is a single import. Then add
`boot.zfs.extraPools = [ "ark" ]`, reboot, and confirm `zpool status -x` reports all
pools healthy. Disks are on plain SATA — no HBA in the way, just never put a RAID card
in front of them later.

- **`zpool upgrade -n` first.** Feature upgrades are one-way. If those disks ever need
  to attach to an older kernel, upgraded features will refuse to import.
- If the pool came from another machine, mountpoints may be baked in. Reset them
  explicitly rather than discovering `/ark` sitting under `/`.
- There is no hypervisor storage abstraction here; the datasets are yours to manage.

### 4.1 Dataset layout

```
ark
├── ephemeral/media/media            # the existing library — exported, never modified
├── vm/plex-os                       # zvol, 64G, guest root disk
├── vm/plex-config                   # zvol, 32G, Plex DB + cache
├── vm/edge-os                       # zvol, 32G
└── backup/                          # zfs send target / staging for external disk
```

**The library is not moved or re-datasets.** Virtiofs exports
`/srv/ark/ephemeral/media/media` as a directory; the guest mounts it read-only. The
`zfs create ark/media` + `mv` dance from earlier drafts existed only to hang dataset
properties and a snapshot policy on the library, which is optional and can be done later
with `zfs mv` (instant, same pool) if you ever want it.

On zvols, `volblocksize=16K` is a sane default; 8K for anything genuinely
database-heavy. If you do carve out a media dataset later, `recordsize=1M`,
`compression=zstd`, `atime=off`, `xattr=sa`, `acltype=posixacl` are the properties to
set.

---

## 5. VM management layer (T2: checked-in domain XML)

libvirt runs the VMs; the definitions live in git. The mechanism is small.

1. Author the VM once in virt-manager (it writes correct XML for you) or by hand.
2. Export the **inactive** config and commit it:
   `virsh dumpxml --inactive plex > hosts/plex/domain.xml`
3. A systemd oneshot defines it on every rebuild, reading straight from the Nix store.

```nix
systemd.services.libvirt-domains = {
  description = "Define libvirt domains from the flake";
  wantedBy = [ "multi-user.target" ];
  after = [ "libvirtd.service" ];
  requires = [ "libvirtd.service" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    ${pkgs.libvirt}/bin/virsh define ${./hosts/plex/domain.xml}
    ${pkgs.libvirt}/bin/virsh autostart plex
    ${pkgs.libvirt}/bin/virsh define ${./hosts/edge/domain.xml}
    ${pkgs.libvirt}/bin/virsh autostart edge
  '';
};
```

`virsh define` is idempotent: re-defining unchanged XML is a no-op, changed XML updates
the stored definition and takes effect on the next VM restart. Because the path is a
flake path, Nix copies the file into the store — read-only, versioned, and unable to
drift from what the repo says. That is the whole trick.

Manage from your laptop once it exists:

```bash
virt-manager --connect qemu+ssh://jim@hyper/system
virsh -c qemu+ssh://jim@hyper/system list --all
```

Host-side libvirt config:

```nix
virtualisation.libvirtd = {
  enable = true;
  qemu.runAsRoot = false;
  allowedBridges = [ "br20" "br30" "br40" "virbr0" ];
};
users.users.jim.extraGroups = [ "libvirtd" ];
services.cockpit.enable = true;                 # optional browser view
environment.systemPackages = with pkgs; [ virt-manager libvirt qemu_kvm ];
```

That is the entire management layer: no web API, no cluster filesystem, no daemon
database beyond libvirt's own.

---

## 6. Network: one bridge per VLAN

libvirt cannot tag VLANs on a plain bridge — `<vlan>` in a domain is for
`hostdev`/SR-IOV only. Fighting that is how people end up with tap interfaces on the
wrong subnet. The pattern that works: **802.1Q sub-interface off the trunk, then a
bridge on top, one per VLAN.** A guest attached to `br30` is simply *on* VLAN 30, with
no tagging anywhere inside the guest.

The switch port stays a plain trunk. No `vlan_filtering`, no `bridge vids`.

### 6.1 VLAN plan (replace with yours)

| VLAN | Name | Subnet | Contents |
|---|---|---|---|
| 10 | mgmt | 10.10.10.0/24 | host .10, IPMI, switch mgmt |
| 20 | apps | 10.20.0.0/24 | internal services, Plex |
| 30 | edge | 10.30.0.0/24 | Caddy, only 80/443 published |
| 40 | dev | 10.40.0.0/24 | testing / development |
| 50 | iot | 10.50.0.0/24 | for IoT devices in the house |

### 6.2 Host networking

```nix
networking = {
  useNetworkd = true;

  vlans.vlan10 = { id = 10; interface = "enp3s0"; };
  vlans.vlan20 = { id = 20; interface = "enp3s0"; };
  vlans.vlan30 = { id = 30; interface = "enp3s0"; };
  vlans.vlan40 = { id = 40; interface = "enp3s0"; };
  vlans.vlan50 = { id = 50; interface = "enp3s0"; };

  interfaces.vlan10.ipv4.addresses = [ { address = "10.10.10.10"; prefixLength = 24; } ];
  interfaces.vlan10.ipv4.routes = [ { address = "0.0.0.0"; prefixLength = 0;
                                      via = "10.10.10.1"; } ];

  bridges.br20.interfaces = [ "vlan20" ];   # apps
  bridges.br30.interfaces = [ "vlan30" ];   # edge
  bridges.br40.interfaces = [ "vlan40" ];   # dev
  bridges.br50.interfaces = [ "vlan50" ];   # iot
};
```

The `brNN` bridges get **no host IP**. They exist to hand a tap to libvirt; traffic is
L2 from guest to switch, so inter-VLAN routing stays on your router. If the host
eventually needs to reach the media VLAN, put the address on `vlan30`, not on `br30`,
and be deliberate about it.

### 6.3 Guest addressing

Fixed IPs set in the guest's own NixOS config (§7): no DHCP dependency, and the reverse
proxy gets a stable target.

### 6.4 Firewall posture

| From | To | Port |
|---|---|---|
| LAN/admin | host | 22 |
| edge (VLAN 30) | plex 10.20.0.20 | 32400 |
| WAN | edge 10.30.0.10 | 80, 443 |
| anything else | anything else | deny |

Enforced twice — on the router (inter-VLAN policy) and in each guest's NixOS firewall.
Not either/or: the second layer is what saves you when the router config is wrong.

---

## 7. Guests: image, define, boot

### 7.1 Repository shape

```
homelab/
├── flake.nix
├── modules/{guest.nix,net-static.nix}
├── hosts/
│   ├── hyper/{default.nix,disko.nix}
│   ├── plex/{default.nix,domain.xml}
│   └── edge/{default.nix,domain.xml}
└── secrets/                       # sops + age, later
```

Guest configs and their domain XML sit side by side, so a VM is one directory.

### 7.2 Build the image, provision the disk

Nixpkgs builds guest images natively now (nixos-generators is deprecated), so the
image comes straight out of the guest's own configuration:

```bash
nix build .#plex-image --out-link result-plex      # ./result-plex/nixos.qcow2

zfs create -V 64G -s ark/vm/plex-os
qemu-img convert -O raw result-plex/nixos.qcow2 /dev/zvol/ark/vm/plex-os
```

Disk stanza in the domain XML:

```xml
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native'/>
  <source dev='/dev/zvol/ark/vm/plex-os'/>
  <target dev='vda' bus='virtio'/>
</disk>
```

`cache='none' io='native'` keeps the guest's writes out of the host page cache, which is
correct for a zvol — ZFS is already caching, and double-caching costs you memory and
buys nothing.

Every guest also gets the agent channel:

```xml
<channel type='unix'>
  <target type='virtio' name='org.qemu.guest_agent.0'/>
</channel>
```

paired with `services.qemuGuest.enable = true;` in the guest, so `virsh shutdown` is a
clean ACPI/agent shutdown rather than a hard power-off.

Growing a disk later: `zfs set volsize=128G ark/vm/plex-os`, then grow the partition
and filesystem inside the guest.

---

## 8. The guests

### 8.1 Shared guest module

```nix
{ pkgs, ... }: {
  services.qemuGuest.enable = true;
  services.openssh = { enable = true; settings.PermitRootLogin = "prohibit-password"; };
  security.sudo.wheelNeedsPassword = false;
  networking.useNetworkd = true;
  networking.firewall.enable = true;
  boot.kernelParams = [ "console=ttyS0,115200n8" ];   # virsh console before network
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "25.11";
}
```

Add a serial getty too, or `virsh console plex` shows you nothing on first boot — which
is exactly when you need it.

### 8.2 Plex VM — VLAN 20 (apps), 10.20.0.20

Media arrives read-only over virtiofs. The Plex database lives on its own zvol, because
SQLite on a shared filesystem is how libraries get corrupted.

```nix
services.plex = { enable = true; openFirewall = false; };  # only the proxy gets in

fileSystems."/media" = {
  device = "media";                        # matches <target dir='media'/>
  fsType = "virtiofs";
  options = [ "ro" "nofail" "x-systemd.automount" ];
};

fileSystems."/var/lib/plex" = {
  device = "/dev/disk/by-label/plex-config";
  fsType = "ext4";
  neededForBoot = true;
};
```

`nofail` + `automount` matter: if virtiofsd dies, the mount hangs like an unreachable
NFS and you do not want that blocking boot.

**The transcoding decision (your §2 item 7).** Hardware transcoding in a VM means full
GPU/iGPU passthrough: IOMMU groups, a vfio stub on the host, and the host losing that
GPU. In a container it is one device line. If you need transcoding, run Plex as a
system container (systemd-nspawn or Incus) with `/dev/dri` and a bind mount, and keep
everything else as VMs — that is the one place a container genuinely beats a VM. If your
clients direct-play, the VM above is right and this paragraph does not apply.

### 8.3 Edge VM — Caddy, VLAN 30 (edge), 10.30.0.10

Caddy rather than Traefik: Traefik's advantage is container-label autodiscovery, and
your services are in separate VMs, so it would run the file provider anyway — several
times the config for the same result.

```nix
services.caddy = {
  enable = true;
  environmentFile = "/run/secrets/cf.env";       # CF_API_TOKEN via sops
  virtualHosts."plex.example.com".extraConfig = ''
    reverse_proxy 10.30.0.20:32400
  '';
};
networking.firewall.allowedTCPPorts = [ 80 443 ];
```

Two things to settle first:

- **DNS is at DigitalOcean, and its Caddy module is not in the stock build.** Either
  use `pkgs.caddy.withPlugins` (needs a `vendorHash`) or use HTTP-01 and skip the
  plugin — which is what the committed config does, since it needs no secrets. DNS-01
  is what lets port 80 stay closed to the internet.
- Plex behind a proxy: terminate TLS at Caddy and set Plex's "secure connections" to
  *Preferred*, not *Required*, or you get redirect loops. Upgrade headers matter for the
  web client.

### 8.4 GPU / transcoding — GTX 960 (GM206)

You have a discrete GTX 960, so the hardware exists; the question is whether it is worth
wiring up. Facts that decide it:

- **GM206 can encode H.264 and HEVC 8-bit, and decode HEVC 10-bit.** Plex does list the
  950/960 as NVENC-capable. It is a 2015 card with the throughput to match — roughly
  1–2 simultaneous 1080p transcodes, not a 4K farm.
- **Driver 580 is the last branch that supports Maxwell.** Beyond that the card is
  frozen on an older driver, so this is a shrinking island, not a long-term plan. In
  nixpkgs that means a legacy driver package, pinned deliberately.
- **In a VM it means full VFIO passthrough**: vfio-pci binding on the host, correct
  IOMMU groups, and the host permanently losing the card. The host is headless, so the
  loss is free — the work is the setup.

Recommendation: **build and prove the VM without the GPU first** (M6), then add
passthrough as its own milestone (M8) only if CPU transcoding actually annoys you. A
4-vCPU VM handles a single 1080p transcode; if everyone direct-plays, you never need
the card at all. If you do add it, the domain gets a `<hostdev>` block and the host gets
a `vfio-pci` stub — neither changes anything else in this plan.

---

## 9. Update loop

### 9.1 Host

```bash
nix flake update                       # bump, read the diff
nixos-rebuild build --flake .#hyper    # build first, fail early
sudo nixos-rebuild switch --flake .#hyper
```

If the new generation breaks libvirt, QEMU or the kernel: reboot and pick the previous
generation in the boot menu, or `sudo nixos-rebuild switch --rollback`. That is the
reason for this architecture — **the hypervisor layer is reversible**, not merely
reinstallable.

### 9.2 Guests

```bash
nixos-rebuild switch --flake .#plex \
  --target-host jim@10.20.0.20 --use-remote-sudo
```

Builds on your workstation, pushes the closure, switches atomically. Same rollback story
inside the guest.

### 9.3 Cadence

- Guests: whenever a service update matters. Weekly is comfortable.
- Host: monthly flake bump; immediately for a security advisory.
- Commit each `flake.lock` bump on its own, so a bad week is `git revert`.

---

## 10. Backups: the data, not the VMs

No VM backups, per your call. What that leaves, in priority order:

1. **`ark/media`** — the only irreplaceable data. ZFS snapshots on a schedule plus
   `zfs send` to an external disk or a second pool. This is the thing that deserves real
   attention.
2. **The flake in git** — host and every guest rebuild from it in minutes.
3. **Secrets** — sops/age keys stored offline, not only on the box.
4. **Nearly free, worth doing**: `zfs snapshot ark/vm/plex-config@pre-update` before
   touching Plex. Costs nothing, saves an evening.

A `zfs send` you have never restored is a rumour. Put one restore on the build list.

---

## 11. Build order

| Step | Work | Est. |
|---|---|---|
| M0 | Answer §2; record the array's `zpool status` / `zfs get all`; confirm the media exists somewhere else right now | 0.5 h |
| M1 | Repo skeleton (flake, `hosts/hyper`, disko); install NixOS on the boot SSD; reboot | 2–3 h |
| M2 | Attach the array, `zpool import`, set dataset properties, reboot, verify healthy | 1 h |
| M3 | Trunk + per-VLAN bridges; confirm traffic lands on the right subnet per bridge | 1 h |
| M4 | libvirtd + define-oneshot; build a throwaway guest; prove define → boot → SSH → rebuild from your laptop | 3–4 h |
| M5 | Edge VM, DNS record, certificate | 1–2 h |
| M6 | Plex VM, virtiofs mount, permission check, library scan | 2 h |
| M7 | Snapshot/send job, `nix.gc`, written runbook, one restore drill | 2 h |

M4 is the gate. Once one guest boots and rebuilds from your laptop, the rest are copies
of a pattern.

---

## 12. Deliberately not here

- **Proxmox, Incus, microvm.nix.** Considered and rejected for this build. microvm.nix
  is the right tool if you later want a pile of tiny stateless services as systemd
  units; it is a poor fit for Plex (read-only root, written DB, no comfortable GPU path).
- **A web UI.** virt-manager over SSH, optionally Cockpit. Nothing to secure.
- **LXC.** systemd-nspawn is available the day a service wants a container boundary
  without a VM, and costs nothing to add.
- **HA/clustering.** One box.

---

## 13. Pitfalls, in the order you will hit them

1. **disko wipes what it is pointed at.** Array disks physically disconnected the first
   time. This is the one mistake that is not recoverable from git.
2. **`zpool upgrade` is one-way.** Run `zpool upgrade -n` and think before upgrading.
3. **virtiofs needs shared memory.** The domain must carry
   `<memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>` and the
   filesystem device `accessmode='passthrough'`. Without it the VM refuses to start with
   an error that never mentions virtiofs.
4. **`virsh dumpxml` without `--inactive` captures runtime state.** Always export with
   `--inactive`, or the committed XML bakes in a transient device.
5. **virtiofs passes host uid/gid through**, and virtiofsd runs as the unprivileged
   QEMU user — `qemu-libvirtd` on NixOS (Debian's `libvirt-qemu` is the name in most
   tutorials, and it does not exist here). For a read-only media mount, `chgrp -R
   qemu-libvirtd` + `chmod -R g+rX`; pin `users.users.plex.uid` only if you need write
   access.
6. **BIOS vs UEFI in the domain.** Decided: guests boot BIOS/GRUB, the host boots
   systemd-boot/UEFI. An image built the other way will not boot. Do not mix.
7. **libvirt does not tag VLANs on a bridge.** Per-VLAN bridges (§6), not `<vlan>`.
8. **SQLite on a shared filesystem** corrupts libraries. Plex DB on the zvol, always.
9. **`nofail` on the virtiofs mount**, or a dead virtiofsd blocks boot.
10. **A `zfs send` you have never restored is a rumour.**
