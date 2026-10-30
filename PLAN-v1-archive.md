# Home server rebuild — design + build plan (v1, for review)

Status: proposal. Nothing here has been executed. Read section 1 first — it is the
one decision that changes most of what follows.

---

## 1. The fork: "NixOS running Proxmox" is not really a thing (yet)

Proxmox VE is a Debian-based distribution. It is not a package you enable on another
distro. There are three honest ways to combine the two, and they are not equivalent:

| | What it is | Update story | Risk |
|---|---|---|---|
| **A. PVE 9 host + NixOS guests** (recommended) | Debian 13 hypervisor, ZFS root, every VM is NixOS from one flake | apt for hypervisor (quarterly), `nixos-rebuild` for everything you actually touch | Low. Both halves are mainstream. |
| **B. proxmox-nixos** (SaumonNet) | A port of PVE onto NixOS; `services.proxmox-ve.enable = true` | `nix flake update` for everything, one syntax | Maintainers say *"still experimental, we do not advise running it on production machines"*. Third-party binary cache, and VM definitions end up split between Nix and the web UI ("two sources of truth"). ~1.4k stars, active. |
| **C. NixOS + libvirt/Incus, no PVE** | Fully declarative hypervisor | Best-in-class | You lose the PVE web UI, PVE backup, snapshot UX, community scripts. |

**Recommendation: A.** Your stated goal is "easily update the system and services".
Services are where the churn is, and under A they are 100% declarative NixOS. The
hypervisor is a stable, rarely-touched layer where boring apt updates are a feature,
not a compromise. You keep the PVE web UI, vzdump, and the LXC fast path.

I am not dismissing B — it is a real project and it does deliver "one flake for the
whole box". But it puts an experimental component at the bottom of the stack, under
your media library, and its own README points at the concrete sharp edge (bridges and
VM definitions live in the UI while your Nix config claims to own them). See §11 for
what changes if you pick it anyway.

Everything below assumes **A** unless marked otherwise.

---

## 2. Assumptions to confirm before we build anything

These change the plan materially. I would rather ask than guess:

1. **NICs** — how many physical ports, and are any 2.5/10 GbE? Determines whether
   storage traffic gets its own VLAN/port or shares the trunk.
2. **Switch** — model, and does the port facing the server support 802.1Q trunks?
   (Managed switch required for any of this.)
3. **VLAN IDs and subnets** — do you already have a scheme, or am I inventing one?
4. **Gateway/firewall** — is there a router doing inter-VLAN routing and firewalling
   (OPNsense/UniFi/…), or is this box expected to route?
5. **ZFS array** — pool name, `ashift`, dataset layout, encryption, and how the disks
   are attached (HBA strongly preferred over a RAID card — RAID cards hide the disks
   from ZFS and often break SMART/scrub).
6. **Boot disks** — separate NVMe pair for the PVE root pool? *Do not* let the PVE
   installer touch the array disks.
7. **GPU** — is there an iGPU/dGPU available for Plex transcoding? This decides
   VM vs LXC for Plex (§6).
8. **Domain + DNS provider** — needed for ACME. Cloudflare? Internal-only DNS?
9. **ISP upload** — decides whether remote Plex streaming is viable at all.

---

## 3. Layer 0 — base NixOS/PVE host

Target: PVE 9.x on Debian 13 (Trixie), ZFS root, no desktop, no surprises.

Layout decisions:

- **Root pool**: `rpool`, mirror of two SSDs, `ashift=12`. PVE installer can do this
  (ZFS RAID1) — use *Advanced* and select only the boot devices.
- **Array**: existing pool, imported read-write, never a PVE storage entry unless we
  deliberately want PVE to manage datasets (§4).
- **Swap**: zram + a small zvol, not a swapfile on ZFS.
- **Host hardening**: SSH keys only, root login by key, `pve-firewall` enabled but
  *not* blocking the trunk, no-subscription repo pinned and tested.

Host `/etc/network/interfaces` (single trunk, management on the native VLAN):

```
auto lo
iface lo inet loopback

iface eno1 inet manual          # the trunk port; no IP here

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.10/24
    gateway 10.10.10.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
```

`bridge-vlan-aware yes` is what makes per-VM `tag=NN` work. Management rides the
switch port's native VLAN (10), so the host needs no sub-interface. If you want zero
untagged traffic, the alternative is a `vmbr0.10` interface holding the IP and the
switch port set to trunk-only; slightly cleaner, slightly more foot-guns. Say which
you prefer.

---

## 4. Layer 1 — ZFS array import

On the host, after install, with the array disks visible:

```bash
zpool import                      # list candidates (should NOT show rpool's disks)
zpool import -f tank              # -f only if hostid mismatch; otherwise plain
zfs set mountpoint=/srv/tank tank
zpool set cachefile=/etc/zfs/zpool.cache tank
systemctl restart zfs-import-cache zfs-mount
# then reboot and confirm: zpool status -x  → "all pools are healthy"
```

Notes that matter:

- Importing an older pool on a newer ZFS may auto-upgrade feature flags. Run
  `zpool upgrade -n tank` first and **do not** upgrade until you are sure you will
  never attach these disks to an older kernel. Upgrade is irreversible.
- If the pool was made elsewhere, mountpoints may be baked in as `/tank/...`.
  Reset them deliberately rather than discovering them under the root filesystem.
- Dataset layout I'd propose (adjust names to taste):

```
tank
├── media/{movies,tv,music,photos}   # ro to VMs, snapshot policy here
├── vm/plex-config                   # zvol, ext4, 32G — Plex DB lives here
├── vm/edge-config                   # zvol, ext4, 16G
├── backups/pve                      # vzdump target
└── shares/                          # LAN shares (SMB/NFS), later
```

Dataset properties worth setting explicitly on `tank/media`:
`atime=off`, `xattr=sa`, `acltype=posixacl`, `recordsize=1M` (large sequential media),
`compression=zstd`.

---

## 5. Layer 2 — getting data into VMs (this is where "bind mount" needs unpacking)

**A VM cannot bind-mount a host directory.** Bind mounts are an LXC feature. For a VM
you have four real options:

| Mechanism | Perf | Semantics | Use for |
|---|---|---|---|
| **virtiofs** (PVE ≥ 8.4) | near-native | POSIX, host-backed | Media library, read-only |
| **zvol → virtio-blk** | native | real block device, guest formats it | Plex DB/config, anything with SQLite |
| **9p** | slow | POSIX, legacy | Nothing, unless virtiofs breaks |
| **NFS/SMB over an internal bridge** | good on virtio-net | network FS | Multi-consumer shares; keeps VM snapshots working |

Recommended split for Plex:

- **Media**: virtiofs, mounted **read-only**. Plex only reads; ro also removes any
  chance of the guest mangling your library.
- **Plex config + metadata DB**: a **zvol**, formatted ext4 inside the guest.
  SQLite on a shared filesystem is the classic way to corrupt a Plex library.

**The virtiofs trade you must accept:** per PVE docs, virtiofs devices make VM
snapshots / memory hotplug / hibernate unavailable (PVE 8; check 9 at build time —
patches exist to relax this). Consequence: **no snapshot-mode vzdump for VMs with a
virtiofs device**. Mitigation: media is already protected by ZFS snapshots at the host
level, and the Plex config lives on a zvol we can snapshot directly. If you would
rather keep VM-level snapshots, use NFS for the media mount instead of virtiofs — the
cost is a little latency and one more service, the gain is ordinary backup semantics.

**The permission gotcha** nobody warns you about: virtiofs passes through host
uid/gid. NixOS allocates `plex` some uid like 972; your dataset is probably
`root:media`. Either pin `users.users.plex.uid = <host uid>` in the guest config, or
chmod the media tree group-readable. Pin the uid — it is one line and it is stable
across rebuilds.

**Configuring the share** (PVE UI): Datacenter → **Directory Mappings** → Add
(name = the tag the guest mounts by, path = `/srv/tank/media`) → VM → Hardware → Add →
**Virtiofs** → Directory ID. There is a `qm set <vmid> --virtiofs0 ...` equivalent;
confirm the exact option set with `man qm` at build time rather than trusting a
snippet.

Guest side, in NixOS:

```nix
fileSystems."/media" = {
  device = "media";              # the Directory Mapping name
  fsType = "virtiofs";
  options = [ "ro" "nofail" "x-systemd.automount" ];
};
```

`nofail` + `automount` matters: if virtiofsd dies, the mount hangs like an unreachable
NFS, and you do not want that to block boot.

---

## 6. Layer 3 — network design

Proposed VLAN plan (replace with yours):

| VLAN | Name | Subnet | Contents |
|---|---|---|---|
| 10 | mgmt | 10.10.10.0/24 | PVE host .10, IPMI, switch mgmt |
| 20 | apps | 10.20.0.0/24 | internal services, DNS, dashboards |
| 30 | media | 10.30.0.0/24 | Plex |
| 40 | edge | 10.40.0.0/24 | Caddy/Traefik; only 80/443 published |
| 50 | iot/guest | 10.50.0.0/24 | optional, isolated |

Three ways to attach a VM, pick per VM:

1. **Tagged NIC on the vlan-aware bridge** (default, simplest):
   `qm set 100 --net0 virtio,bridge=vmbr0,tag=30`. The guest sees *untagged* traffic
   and just configures `eth0` normally. No VLAN config inside the guest at all.
2. **Per-VLAN bridges** (`vmbr30` with its own `bridge-ports`/`bridge-vids`): more
   explicit, no `tag=` anywhere. Useful if you like reading the config and knowing
   exactly what exists.
3. **Trunk into the VM** (`tag` omitted) + 802.1Q in the guest. Only when one VM must
   live on several VLANs — a router/firewall VM, or an edge VM that needs both VLAN 40
   and 30. This is the only case that requires guest-side VLAN config:

```nix
networking.vlans."vlan40" = { id = 40; interface = "eth0"; };
networking.interfaces."vlan40".ipv4.addresses = [
  { address = "10.40.0.10"; prefixLength = 24; }
];
```

(With `networking.useNetworkd = true` this is expressed as a
`systemd.network.netdevs` VLAN device instead; the `networking.vlans` option still
works under the scripted backend. I'll pick one and be consistent.)

Guest static IP, the common case:

```nix
networking = {
  useNetworkd = true;
  hostName = "plex";
  firewall.enable = true;
  interfaces.eth0.useDHCP = false;
  defaultGateway = "10.30.0.1";
  nameservers = [ "10.10.10.53" ];
  interfaces.eth0.ipv4.addresses = [ { address = "10.30.0.20"; prefixLength = 24; } ];
};
```

Firewall posture: edge VM accepts 80/443 from anywhere; apps/media VMs accept their
service port only from VLAN 40 (the proxy), plus SSH from mgmt/admin. Nothing in
VLAN 20/30/40 initiates to mgmt. If the router already firewalls inter-VLAN, the
per-host rules are the second layer, not the only one.

---

## 7. Layer 4 — the two VMs

### 7.1 Repository / flake shape

```
homelab/
├── flake.nix
├── modules/
│   ├── guest.nix          # ssh, qemu-guest-agent, user, firewall defaults
│   └── net-static.nix
├── hosts/
│   ├── plex/default.nix
│   └── edge/default.nix
└── secrets/               # sops-nix, later
```

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = { url = "github:Mic92/sops-nix"; inputs.nixpkgs.follows = "nixpkgs"; };
  };
  outputs = { self, nixpkgs, ... }@inputs: {
    nixosConfigurations.plex = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [ ./modules/guest.nix ./hosts/plex ];
    };
    # edge = ...
  };
}
```

### 7.2 Building the image and creating the VM

`nixos-generators -f proxmox` (VMA) exists and is the documented path, but it is
historically flaky. I would use **qcow2 + `qm importdisk`**, which is boring and works:

```bash
nix run github:nix-community/nixos-generators -- -f qcow2 -c hosts/plex -o ./out

qm create 100 --name plex --memory 8192 --cores 4 \
  --scsihw virtio-scsi-pci --ostype l26 \
  --net0 virtio,bridge=vmbr0,tag=30 \
  --agent enabled=1 --serial0 socket
qm importdisk 100 ./out/nixos.qcow2 local-zfs
qm set 100 --scsi0 local-zfs:vm-100-disk-0 --boot order=scsi0
```

Add `boot.kernelParams = [ "console=ttyS0,115200n8" ]` plus a serial getty so
`qm terminal 100` works before networking is up — you will want it the first time DHCP
or the firewall is wrong.

### 7.3 Plex

Decision point (**§2 item 7**): hardware transcoding.

- **No transcoding needed** (clients direct-play): Plex as a NixOS VM is clean.
- **Transcoding on CPU**: works, but a VM eats cores; fine for one stream.
- **Hardware transcoding**: in a VM this requires full iGPU/GPU passthrough (VFIO),
  which means the host loses that GPU and you must get IOMMU groups right. In an
  **LXC** it is a two-line config (`dev0: /dev/dri/renderD128`) plus a bind mount for
  the media, i.e. dramatically less work — *but* an LXC is not NixOS, so you trade
  declarative management for it.

My read: if you need transcoding, run Plex as a PVE LXC (Debian or a NixOS-generated
LXC rootfs) instead of a VM, and keep everything else as NixOS VMs. If you don't need
transcoding, the VM in this plan is right. This is the one place where your answer
changes the architecture, so it is worth deciding before we build.

VM config sketch:

```nix
services.plex = {
  enable = true;
  openFirewall = true;          # 32400; tighten to VLAN 40 if proxied
};
users.users.plex.uid = 972;     # match host dataset ownership (§5)
fileSystems."/media" = { device = "media"; fsType = "virtiofs";
                         options = [ "ro" "nofail" "x-systemd.automount" ]; };
```

### 7.4 Caddy (or Traefik)

**Caddy**, unless you have a reason otherwise. Traefik's main advantage is Docker
label autodiscovery; your services are in separate VMs, so Traefik would run file
provider anyway — at which point Caddy is a fifth of the config.

```nix
services.caddy = {
  enable = true;
  environmentFile = "/run/secrets/cf.env";     # CF_API_TOKEN, sops-decrypted
  virtualHosts."plex.example.com".extraConfig = ''
    reverse_proxy 10.30.0.20:32400
  '';
};
```

Certificates: **DNS-01** (Cloudflare plugin) so you never need port 80 open to the
world. HTTP-01 also works if 80 is forwarded.

Two things to get right:

- The edge VM lives on VLAN 40 and must reach 10.30.0.20:32400. That is an inter-VLAN
  rule on the router *and* an allow in the guest firewall — both, not either.
- Plex over a reverse proxy needs `Connection`/`Upgrade` handling and correct
  `X-Forwarded-*`; also decide whether to keep Plex's own TLS (`plex.direct`) or
  terminate at Caddy. Terminating at Caddy is simpler; Plex's "secure connections"
  setting then goes to *Preferred*, not *Required*.

---

## 8. Update strategy (the actual point of the exercise)

Two loops, deliberately different speeds:

**Services (NixOS VMs)** — this is the loop you will use weekly:

```bash
nix flake update                 # bump nixpkgs, read the diff
nixos-rebuild build --flake .#plex      # build first, fail early
nixos-rebuild switch --flake .#plex \
  --target-host root@10.30.0.20 --use-remote-sudo
```

- The build happens on your workstation; the closure is pushed to the guest. Guests
  need no compiler and no internet.
- Every switch is an atomic generation. `nixos-rebuild switch --rollback` on the guest
  reverts in seconds — that is the whole reason to do this.
- Keep `system.autoUpgrade` **off** on servers. Run `nix.gc` weekly.
- Commit the `flake.lock` bump as its own commit so a bad upgrade is one `git revert`
  away.

**Hypervisor (PVE)** — quarterly, boring, manual:

1. `zfs snapshot rpool/ROOT/pve-1@pre-update`
2. `apt update && apt full-upgrade` on the no-subscription repo
3. Read the PVE upgrade notes for the minor version — kernel/ZFS bumps sometimes need
   a reboot before the second half applies
4. Reboot, verify `zpool status -x` on both pools

Rollback for the host is a ZFS dataset rollback, which is why keeping the root pool on
ZFS is worth it independent of everything else.

---

## 9. Backups

- **VM disks**: vzdump → `tank/backups/pve`, weekly, keep 3. Note the virtiofs
  caveat in §5 — VMs with a virtiofs device lose snapshot-mode backups; plan on
  `mode=stop` for Plex or move media to NFS.
- **Media**: ZFS snapshots + `zfs send` to an external disk or second pool. This is
  the data you cannot re-download; treat it as the primary backup target.
- **Config**: the flake in git, secrets in sops with the age key stored offline.
  A rebuild from bare metal should be: install PVE, import pool, `git clone`,
  `nixos-rebuild` × N.

Test one restore before you trust any of it. An untested backup is a rumour.

---

## 10. Build order

| Step | Work | Est. |
|---|---|---|
| M0 | Confirm §2 answers; inventory disks/NIC/GPU; back up the array's data elsewhere if it is currently live | 0.5 h |
| M1 | Install PVE 9 on mirrored SSDs (ZFS root), configure trunk + vlan-aware bridge, verify mgmt reachability | 2–3 h |
| M2 | Import the array, set dataset properties, verify survives reboot, take a baseline snapshot | 1 h |
| M3 | Create VLANs on switch; verify a throwaway VM gets the right subnet per tag | 1 h |
| M4 | Flake skeleton + `guest.nix`; build and boot one NixOS VM; prove the deploy loop end to end | 3–4 h |
| M5 | Edge VM + DNS + certificate issuance | 1–2 h |
| M6 | Plex VM + virtiofs mount + uid match + library scan | 2 h |
| M7 | Backups, `nix.gc`, update runbook, one restore drill | 2 h |

M4 is the gate: once `nixos-rebuild switch --target-host` works for one guest, the
rest are copies of a pattern.

---

## 11. If you want literal "NixOS running Proxmox" anyway

Under **B (proxmox-nixos)**, the deltas from the above:

- Host config becomes `services.proxmox-ve.enable = true` + `bridges = [ "vmbr0" ]`;
  the bridge is declared in NixOS *and* once in the UI so the UI can list it.
- PVE updates track the flake's pinned nixpkgs, not the PVE repo. Adding the
  SaumonNet binary cache is effectively mandatory or you will build PVE's Perl stack
  from source.
- VM definitions stay in the UI/`/etc/pve` — Nix does not own them, so "reproduce the
  whole box from git" is only true for the hypervisor layer.
- Backup/snapshot behaviour is PVE's, unchanged.
- Accept that you are the QA for a project its own authors call experimental, and that
  a broken hypervisor update means fixing it from a rescue shell.

The guests, VLANs, virtiofs mappings and ZFS import in §4–§7 are identical in both
worlds. Only §3 and the host-side update loop change. So choosing A now does not lock
you out of B later — you can move the host config over in an afternoon once you are
comfortable.

---

## 12. What I need from you

Answer 1–9 in §2, plus:

- A or B (§1), and VM or LXC for Plex (§7.3).
- Do you want the plan to include an actual **router/firewall VM** (OPNsense) on this
  box, or does your existing router do inter-VLAN routing? This changes §6.
- Rough disk budget for `rpool` vs array, and total RAM.

---

## 13. Addendum — rolling host distros, and life after Proxmox

Added after the review question "I want a rolling-release host, and I'm not tied to
Proxmox". Supersedes §1 if option **D** below is chosen.

### 13.1 What Proxmox's update model actually is

PVE is Debian stable + its own repos. Between major versions you get a continuous
stream of minor updates (`apt full-upgrade` monthly is normal and safe). The
"big bang" is the Debian base bump — PVE 8 → 9 moved bullseye → trixie, roughly every
two years, and it is the one operation that can half-finish.

Putting PVE on Debian testing or sid is **not supported** and is the standard way to
end up with an unbootable hypervisor. So "rolling Proxmox" is not a configuration
that exists; it is a choice of a different hypervisor.

### 13.2 Rolling ≠ reversible. Decide which one you want.

- **Rolling** (Arch, Tumbleweed): packages drift continuously. You get new features
  fast and breakage on an ordinary Tuesday, with no built-in undo.
- **Atomic + reversible** (NixOS, MicroOS): updates land as a whole system state you
  can roll back in one command or one reboot.

For a hypervisor — the layer whose failure takes down every guest at once — the
second property is worth more than the first. A 2-year big-bang upgrade that you can
snapshot-and-rollback is *less* risky than continuous drift you cannot undo. That is
why option A in §1 was recommended, and it is why the discussion below leads with
NixOS rather than with "the most rolling thing".

### 13.3 The options

| | Rolling? | Atomic / rollback | Isolation model | ZFS | Verdict |
|---|---|---|---|---|---|
| **D. NixOS unstable + Incus** | yes (flake-pinned, you choose when) | yes, per-generation, instant | system containers **and** VMs, one CLI | native pool driver, snapshots | **best fit for your stated goals** |
| **E. openSUSE MicroOS + KVM** | yes (Tumbleweed snapshots) | yes, btrfs transactional, health-checker auto-rollback | VMs (libvirt), podman containers | yes | best "traditional distro that behaves like an appliance" |
| **F. Arch + libvirt/Incus** | yes, genuinely | no (snapper approximates) | VMs / containers | yes | fine, but you are the QA |
| **G. Fedora Server + libvirt** | no, but fast 13-month cadence | dnf history undo | VMs | yes | boring and current, not rolling |
| **H. Keep PVE** | no | ZFS snapshot of rpool | VMs + LXC | best-in-class | still the best UI/backup story |

### 13.4 Recommended: NixOS (unstable) + Incus

This is the thing you were originally reaching for — a declarative NixOS host running
a hypervisor — without the experimental PVE port from §1 option B. Incus 7.0 LTS
(May 2026) is the LXC team's own fork of LXD, Apache-2.0, and it manages **system
containers and full VMs through the same API and CLI**.

Why it fits the original requirements:

- **Bind mounts, for real.** `incus config device add plex media disk
  source=/srv/tank/media path=/media readonly=true` — an actual bind mount into the
  instance. This is the thing §5 had to work around for VMs. For VMs the same device
  is backed by virtiofs (or 9p), so the interface is identical either way.
- **VLANs per NIC.** `incus config device add plex eth0 nic nictype=bridged
  parent=br0 vlan=30` on a vlan-filtering bridge. Trunks: `vlan=10
  vlan.tagged=20,30` — the same model as §6, less YAML.
- **ZFS is the native storage driver.** Pool over your array, per-instance datasets,
  instant snapshots, `incus copy` between pools.
- **Guests can be NixOS.** nixpkgs ships `virtualisation/incus-virtual-machine.nix`
  and `lxc-container.nix` modules, so you can build custom Incus images from the same
  flake and keep the deploy loop from §8 inside the guests.
- **Isolation is a real step up from bare-metal containers**: system containers have
  their own init, PID/net/mount/user namespaces and a full distro userland, and you
  escalate to a VM per service whenever you want a kernel boundary.

**Honest costs:**

- Incus instances are **imperative**. State lives in Incus's database, not in git, so
  "reproduce the box from the flake" is only true for the *host*. Mitigation: a
  `systemd.services.incus-seed` oneshot that runs idempotent `incus` commands, which
  gets you 90% of declarative with none of the lying.
- Declarative instance creation in the NixOS module is still an **open feature
  request** (nixpkgs #386841). Do not wait for it.
- No PVE-style web UI. `incus` CLI plus Cockpit if you want a browser. No vzdump —
  backups are `incus snapshot` + `incus export`, or ZFS `send`.
- NixOS unstable is rolling *and* you can pin it; upgrade when you choose. That is the
  point, but it does mean you own the "when".

### 13.5 If you would rather have a familiar distro

**MicroOS** is the one to look at: read-only root, `transactional-update` applies
updates to a btrfs snapshot, and `health-checker` reboots back to the last working
snapshot automatically if the system fails to come up. It is a Tumbleweed derivative
built for hosts that run containers and VMs. You manage VMs with `virt-manager`,
`virsh` or Cockpit — there is no PVE equivalent web UI, and no LXC convenience layer
(it ships podman instead; Incus can be installed on top).

### 13.6 What carries over regardless

§4 (ZFS import), §5 (data into instances), §6 (VLAN plan), §7.2 (image build),
§8 (update loop, adapted), §9 (backups) and §10 (build order) are all
hypervisor-agnostic in shape. Choosing D changes §1, §3 and §7.4's management layer;
it does not restart the project.

---

## 14. Addendum 2 — vanilla PVE, and dropping VM backups

Decision taken: run Proxmox VE itself, plain, and treat VM backups as out of scope.
Settles the fork in favour of §1 option **A**. This section is the revision.

### 14.1 "Proxmox with QEMU/KVM" is not a variant — it is the product

PVE **is** QEMU/KVM plus a management layer: LXC, pmxcfs (`/etc/pve`), the web UI/API,
storage plugins, virtiofs UI, and vzdump. There is nothing to strip out or swap in; the
only real alternative is raw QEMU + libvirt, where you assemble the bridge plumbing,
VLAN attachment and image handling yourself. So the answer to "what if we just ran
PVE + KVM" is: that is §1 option A, and it is a good default.

Both of the objections I raised against it disappear under your new constraint:

| Objection | Why it no longer applies |
|---|---|
| No rolling / atomic host | The host is about to become disposable (§14.2) — downtime, not data loss, is the failure mode |
| virtiofs disables VM snapshots (§5) | You do not want VM snapshots. Use virtiofs freely; no need to fall back to NFS |

### 14.2 VM backups were doing a second job: they were your host's undo button

Without them, the thing that makes a botched base upgrade survivable is not a backup —
it is that **the VM disks are ZFS datasets/zvols on the array, and reinstalling the host
does not touch them**:

```
reinstall Debian 13 + PVE  →  zpool import tank  →  qm create <same vmid>
→  qm rescan --vmid <vmid>  →  re-attach the existing zvols  →  boot
```

That is the whole disaster plan, and it takes under an hour. It is also why the
rolling-release question dissolves: with a rebuildable host, "big bang" means a
scheduled evening, not a rescue mission. **Consequence: treat the host as cattle.**
Write the rebuild procedure down *before* you need it, and keep it in the repo.

### 14.3 The one thing you should still save, and it is not a backup of a VM

`/etc/pve` is the VM definition database (pmxcfs, backed by `/var/lib/pve-cluster`) —
VMIDs, disk ordering, MAC addresses, PCI mappings, cloud-init. Rebuilding it by hand
from memory is the genuinely annoying part of a rebuild, and it is ~1 MB:

```bash
tar czf /root/pve-etc-$(date +%F).tgz /etc/pve
```

Do that before every host upgrade, and copy it off the box. Cheap insurance, unrelated
to VM backups.

### 14.4 Revised update loop

Unchanged from §8 for the guests — NixOS VMs still rebuild from the pinned flake and
still roll back per generation. That was the part you actually wanted declarative, and
it is untouched.

For the host, two tiers:

- **Monthly**: `apt update && apt full-upgrade` (no-subscription repo). Continuous,
  low risk, no reboot usually needed.
- **Base bump (~2-yearly, e.g. 9 → 10)**: `zfs snapshot rpool/ROOT/pve-1@pre`, tar
  `/etc/pve`, follow the official upgrade guide, reboot, `zpool status -x`. If it goes
  sideways: either roll the snapshot back, or exercise §14.2. Both are acceptable
  outcomes now that the guests' disks live outside the host.

### 14.5 What this deletes from the plan

- §9's vzdump schedule and the `mode=stop` workaround — gone.
- §13's Incus/MicroOS comparison — recorded as considered, not chosen.
- §5's NFS fallback — optional, for convenience only.
- §11 (experimental PVE-on-NixOS) — moot.

### 14.6 What still matters, in priority order

1. **The array's contents.** Media is the only irreplaceable thing here. ZFS snapshots
   plus `zfs send` to an external disk or a second pool. This is not optional and it is
   not the same question as VM backups.
2. **The flake in git.** Every guest is rebuildable from it in minutes.
3. **`/etc/pve` tarball.** Turns a host rebuild from an afternoon into an hour.
4. **The written rebuild procedure.** Untested runbooks are rumours too.

---

## 15. Addendum 3 — the actual answer: NixOS + libvirt/QEMU

**This supersedes §13 and §14.** Constraint stated: NixOS host, plain QEMU/KVM, most of
Proxmox's features are not wanted. That is §1 option **C**, and it is the closest thing
to everything requested across the whole thread: rolling-but-pinned host, atomic
rollback, declarative guests, no management daemon you do not need.

Sections that survive unchanged: §4 (ZFS import), §6 (VLAN plan), §7.1 (flake shape),
§7.3–7.4 (Plex and Caddy as guests), §8 (guest update loop), §10 (build order).
Sections that die: §3 (PVE host), §5 (virtiofs via PVE Directory Mappings), §9, §14.

### 15.1 Three tiers of "declarative VMs on NixOS" — pick one

| Tier | What it is | Declarative? | Cost |
|---|---|---|---|
| **T1. libvirtd + virt-manager** | normal libvirt; domains live in `/var/lib/libvirt` | no (imperative, editable in GUI) | state outside git |
| **T2. libvirtd + checked-in domain XML** | `virsh define` from a file in the repo via a systemd oneshot | yes, in libvirt's own schema | you hand-edit XML |
| **T3. microvm.nix** | each VM is a systemd service built from the flake; no libvirt daemon | fully | read-only root, shared `/nix/store`, no migration, thin GPU story |

Recommendation: **T2 for Plex and the edge VM, T3 later for stateless services.**
Workflow that makes T2 painless: build the VM once in virt-manager (it writes correct
XML for you), `virsh dumpxml plex > hosts/plex/domain.xml`, check that in, then let a
oneshot `virsh define` it on every rebuild. You get a GUI for authoring and a file in
git as the source of truth, without adopting a third-party schema.

Do **not** reach for NixVirt (the `virtualisation.libvirt.connections.*.domains`
module) as a first move: its own README says the master branch is frequently broken,
it is consumed via FlakeHub, and it implements a subset of the domain XML. Fine to
revisit once the XML is stable.

T3 (microvm.nix, by Numtide, CI-tested against unstable + stable) is genuinely good and
worth knowing about: VMs as `systemd.services`, virtiofs/9p shares, tap networking with
vhost (~10 Gbps), block volumes, boot in single-digit seconds, shared read-only
`/nix/store`. Ideal for the "many small services" case. Poor fit for Plex: read-only
root plus a persistently-written SQLite DB is fighting the model, and hardware
transcoding needs device passthrough it does not do comfortably.

### 15.2 Host shape

NixOS unstable (pinned in `flake.lock`), ZFS root via disko, array imported per §4.
Minimum viable host:

```nix
virtualisation.libvirtd = {
  enable = true;
  qemu.runAsRoot = false;
  allowedBridges = [ "br20" "br30" "br40" "virbr0" ];
};
users.users.jim.extraGroups = [ "libvirtd" ];   # virt-manager over SSH
services.cockpit.enable = true;                  # optional browser UI
environment.systemPackages = [ pkgs.virt-manager pkgs.qemu_kvm ];
```

That is the entire hypervisor layer. No web UI to secure, no API, no cluster daemon.

### 15.3 Networking: one bridge per VLAN (do not fight libvirt's VLAN handling)

libvirt does **not** tag VLANs for you on a plain bridge interface — `<vlan>` is for
`hostdev`/SR-IOV, not `type='bridge'`. The pattern that just works is a fake bridge per
VLAN: 802.1Q sub-interface off the trunk, then a bridge on top of it. Each VM attaches
to `br30` and is simply *on* VLAN 30; nothing in the guest knows about tags.

```nix
networking = {
  vlans.vlan10 = { id = 10; interface = "eno1"; };   # host management
  vlans.vlan30 = { id = 30; interface = "eno1"; };   # media
  vlans.vlan40 = { id = 40; interface = "eno1"; };   # edge

  interfaces.vlan10.ipv4.addresses = [ { address = "10.10.10.10"; prefixLength = 24; } ];
  interfaces.vlan10.ipv4.routes = [ { address = "0.0.0.0"; prefixLength = 0;
                                      via = "10.10.10.1"; } ];

  bridges.br30.interfaces = [ "vlan30" ];            # no host IP on these
  bridges.br40.interfaces = [ "vlan40" ];
};
```

Add `br20`/`vlan20` the same way when the first app VM exists. Switchport stays a plain
trunk; no `vlan_filtering`, no `bridge vids`, no `tag=` in the domain XML.

### 15.4 Disks: zvol per VM, raw, on the array

```bash
zfs create -V 64G -s tank/vm/plex-os          # sparse zvol
qemu-img convert -O raw out/nixos.qcow2 /dev/zvol/tank/vm/plex-os
```

Domain XML: `<disk type='block' device='disk'><driver name='qemu' type='raw'/>
<source dev='/dev/zvol/tank/vm/plex-os'/><target dev='vda' bus='virtio'/></disk>`.

zvol + raw is the fast path (no qcow2 layer, no double caching) and it snapshots with
`zfs snapshot`. Grow with `zfs set volsize=128G tank/vm/plex-os` then resize inside the
guest. If you would rather keep qcow2 files on a dataset, that works too — simpler to
resize, a bit slower; not worth it for two VMs.

### 15.5 Media into the VM: virtiofs, four lines of XML

```xml
<domain>
  <memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>
  <devices>
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='/srv/tank/media'/>
      <target dir='media'/>
    </filesystem>
  </devices>
</domain>
```

The `memoryBacking` block is mandatory — virtiofs needs shared memfd memory, and
omitting it is the classic "why won't my VM start" error. Guest side is the same
`fileSystems."/media" = { device = "media"; fsType = "virtiofs"; ... }` from §5, and
the uid-matching warning there still applies.

Note there is no PVE-style Directory Mapping layer here — you point at a host path
directly, which is exactly what was wanted.

### 15.6 Update loop

```bash
nix flake update && nixos-rebuild build --flake .#hyper   # host
sudo nixos-rebuild switch --flake .#hyper
```

If the new generation breaks libvirt, QEMU or the kernel: reboot and pick the previous
generation in the boot menu, or `nixos-rebuild switch --rollback`. **That is the thing
PVE could not give you** — the hypervisor layer itself becomes reversible, not just
sheet-metal-reinstallable. Guests keep the §8 loop.

Add `nix.gc.automatic` + `nix.optimise.automatic`, keep `system.autoUpgrade` off, and
bump the flake on your schedule.

### 15.7 What you are giving up, honestly

- **A web UI for VM lifecycle.** virt-manager (over SSH, from your laptop) is good;
  Cockpit is decent. Neither is the PVE tree.
- **LXC.** systemd-nspawn exists; Incus can be bolted on later (§13) without changing
  the host much.
- **Storage-pool abstraction.** You run `zfs create -V` and attach paths. More typing,
  fewer abstractions, fewer surprises.
- **An ecosystem.** No community-scripts, no forum thread for your exact error. NixOS
  has its own excellent docs, but the "copy-paste a helper script" era is over.
- **Snapshots across virtiofs.** Same QEMU constraint as before; you said you do not
  care, and `zfs snapshot` on the zvol covers the OS disk anyway.

### 15.8 Still open (unchanged from §2/§12)

NICs and switch model · VLAN IDs/subnets and who routes between them · ZFS pool name,
ashift and how disks attach (HBA, not RAID card) · boot disk plan · GPU (decides
Plex as VM vs container) · domain + DNS provider · T1/T2/T3 preference above.
