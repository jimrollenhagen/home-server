# Installing `hyper` without touching the machine

Three routes. Route 1 needs nothing but the Fedora install that is already on the box.

---

## Route 1 — nixos-anywhere over SSH (recommended)

`nixos-anywhere` kexecs the running Fedora into a NixOS installer in RAM, then runs
disko, `nixos-install`, and reboots into the new system. No USB, no PXE, no boot-order
changes — the SSD's ESP ends up holding systemd-boot, so the machine boots NixOS on its
own afterwards.

### Before you start

1. **Secure Boot off.** kexec jumps to an unsigned NixOS kernel. Check on the target:
   `mokutil --sb-state`. If it says enabled, disable it in firmware first (you will also
   want it off for the GTX 960 passthrough later).
2. **Root SSH on the Fedora box**, or a user with passwordless sudo:
   `ssh root@<fedora-ip> true` should succeed.
3. **The array's data exists elsewhere.** disko only touches the device named in
   `hosts/hyper/disko.nix`, but a wrong by-id path is unrecoverable. Confirm it:
   `ls -l /dev/disk/by-id/ | grep -v part`
4. **VLAN 10 exists on the UDM Pro** (README §1). After install the host's only address
   is `10.10.10.10` on `vlan10`. If that network is not there yet, the box comes up
   unreachable and you are back on the console.

### Dry run first

```bash
nix run github:nix-community/nixos-anywhere -- \
  --vm-test --flake .#hyper
```

This builds the system and runs your disk config inside a throwaway VM. If the disko
layout is wrong, you find out here instead of on the real disk.

### The real thing

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#hyper \
  --target-host root@<fedora-ip> \
  -i ~/.ssh/id_ed25519
```

Default phases are `kexec,disko,install,reboot`. It will wipe the boot SSD and reboot
into NixOS. Expect 10–25 minutes, most of it copying the closure.

When it comes back:

```bash
ssh jim@10.10.10.10          # keys from modules/keys.nix, password "changeme"
sudo passwd
```

If you need to re-run after a failure, `--phases disko,install,reboot` skips the kexec
(useful when the target is already a NixOS installer).

---

## Route 2 — custom installer ISO (USB)

For when you would rather not kexec the old OS, or the machine is headless and you want
a known-good environment. `.#installer-iso` is the stock minimal installer plus sshd
running and your keys on root (`modules/installer.nix`).

```bash
nix build .#installer-iso --out-link result-iso
sudo dd if=$(readlink -f result-iso)/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Boot it once (F12 / one-time boot menu — you do not need to change the permanent boot
order). It takes DHCP on the trunk's untagged network, so find it on the UDM's client
list, then:

```bash
ssh root@<dhcp-address>
```

From your laptop, install into it — no kexec needed, the target is already an installer:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#hyper \
  --target-host root@<dhcp-address> \
  --phases disko,install,reboot
```

Alternatively, drive it by hand from the ISO: `disko --mode destroy,format,mount
hosts/hyper/disko.nix` then `nixos-install --flake .#hyper` — that is what
nixos-anywhere automates.

---

## Route 3 — PXE (only if you cannot touch it at all)

The UDM Pro does not serve TFTP, so this means running dnsmasq/nginx on another host.
`netboot.xyz` is the least-effort option (its menu has a NixOS installer entry), served
from a small container or VM elsewhere on the LAN:

```
# on a helper host
dnsmasq --enable-tftp --tftp-root=/srv/tftp --dhcp-boot=netboot.xyz.kpxe
```

or build iPXE assets from this flake's system (`system.build.netbootIpxeScript`) and
serve those. You still need the SSH-in-installer trick from Route 2 to avoid a physical
keyboard, so in practice PXE only saves you walking to the machine — it does not
automate anything Routes 1 and 2 do not.

---

## What is *not* automated: fully unattended install

"Plug in the USB and walk away" is possible — a systemd oneshot in an installer image
that runs disko + `nixos-install` on boot, gated behind a custom kernel parameter so it
cannot fire by accident. I left it out on purpose: it turns a typo in `disko.nix` into
an unrecoverable disk wipe with nobody watching. Ask if you want it and I'll add it
behind an `autoinstall` kernel arg.

## After the first boot

```bash
# on the host
nix flake update && sudo nixos-rebuild switch --flake .#hyper
# guests: build, provision zvols, write images — README §4–§6
```
