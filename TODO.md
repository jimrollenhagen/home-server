# TODO

State when this was written: the repo covers M1–M6 of `PLAN.md` §11 — host config, per-VLAN
bridges, libvirtd + the define-oneshot, both domain XMLs, guest images, and the Plex config
import path. Nothing in `*.nix` mentions snapshots, `zfs send`, SMART or alerting, so **M7 is
the whole remaining milestone**, plus a couple of one-line correctness fixes.

Order matters: the snapshot policy is cheap and can land today; the send target needs a
hardware/accounting decision from you; the drill needs the send.

---

## 0. Decisions before any config

- [ ] **Send target for the library.** `PLAN.md` §10 leaves this vague and it is the only
      choice that changes the design.
      - external USB disk, plugged in and rotated by hand — works now, no subscription,
        but it is a chore you will skip exactly when it matters
      - second pool / NAS on the network — best answer, needs hardware you may not have
      - cloud (B2/S3) — unrealistic for tens of TB of media over 1 Gbps up; fine for
        `plex-config`, the flake and secrets (a few hundred MB)
      - my read: incremental `zfs send -i` to a USB disk for the library, `restic` to B2
        for the small irreplaceable bits. No cloud for media.
- [ ] **How the box tells you something is wrong.** It is headless, has no MTA, and
      `services.zfs.autoScrub` is already on — so scrubs run and nobody reads the result.
      - ntfy (push to phone, one curl, no inbound)
      - healthchecks.io dead-man switch (you learn when a job *stops*, not just when it fails)
      - mail — needs a relay, not worth it without one already running
      - my read: healthchecks for the backup/scrub jobs *and* ntfy for hard failures
        (pool degraded, SMART failure). Belt and braces, both are one-liners.
- [ ] **Retention windows.** Suggested: hourly 24, daily 30, weekly 8, monthly 12 on the
      library; `plex-config` wants more granular recent snapshots (it is the thing a bad
      Plex upgrade corrupts).
- [ ] **Optional: own dataset for the library.** `zfs create ark/media && zfs mv
      /srv/ark/ephemeral/media/media ark/media` (instant, same pool) — makes dataset
      properties and one snapshot policy easy to attach. Not required; sanoid can name the
      path instead. Decide once, because it changes every path in the docs.

---

## 1. M7a — snapshot policy on `ark`

- [ ] Write `modules/zfs-snapshots.nix`, imported by `hosts/hyper`. Sanoid over a hand-rolled
      timer: retention pruning is the part people get wrong, and it is ~40 lines of INI
      against ~30 lines of fragile bash.
- [ ] Cover `ark/ephemeral/media/media` (library) and `ark/vm/plex-config` (Plex SQLite).
- [ ] `use_template = production` for the library; a denser, shorter-retention policy for
      `plex-config`.
- [ ] Also snapshot before touching Plex — either a sanoid `hourly` that is frequent enough
      to not care, or a hook in the update runbook.
- [ ] Acceptance: `zfs list -t snapshot` shows the expected set after an hour;
      `sanoid --monitor-health` exits clean; pruning actually removes old snapshots
      (check after a day, not just that it creates them).

Files: `modules/zfs-snapshots.nix` (new), `hosts/hyper/default.nix` (import).

---

## 2. M7b — get a copy off this box

- [ ] `zfs send -i` incremental script from the last common snapshot to the target.
      Handle `receive_resume_token` (`zfs get receive_resume_token <target>`) or a killed
      send means starting over.
- [ ] systemd oneshot + timer on `hyper`, `Persistent = true`, run after the sanoid
      snapshot timer. Not a cron job in the guest.
- [ ] `restic` job for what git cannot rebuild in minutes: `plex-config` (if you want the
      watch state), `modules/`, and later the sops age key. B2 or equivalent.
- [ ] Log every run to the journal with enough detail that a failure is diagnosable from
      `journalctl -u <unit>` alone.
- [ ] Acceptance: target shows the same snapshot names as the source
      (`zfs list -t snapshot -o name -s creation` on both, diffed); a second run is
      incremental and takes seconds, not hours.

Files: `modules/zfs-backup.nix` or `scripts/zfs-send.sh` + a unit, `hosts/hyper/default.nix`.

---

## 3. M7c — restore drill

`PLAN.md` §10: "A `zfs send` you have never restored is a rumour."

- [ ] Restore one snapshot of the library to a scratch dataset on the array (or to a
      throwaway zvol), verify a handful of media files by checksum, then destroy it.
- [ ] Restore `plex-config` into a test VHD/zvol and confirm Plex opens the database.
- [ ] Write the procedure into a new `README.md` §9 ("Restore"), with the real commands you
      ran, not the ones you meant to run.
- [ ] Put a recurring reminder somewhere: one drill per year, minimum.

---

## 4. M7d — alerting, so failure is not silent

- [ ] `services.smartd` on the array disks. It has no mail transport here, so use
      `-M exec` pointing at a small notify script rather than `-m root`.
- [ ] Pool health check: `zpool status -x` on a timer (or a ZED hook) → notify on anything
      that is not "all pools are healthy".
- [ ] Scrub result: `zpool status -v` after
      `systemctl start zfs-scrub-ark` — surface any `errors:` count or repaired blocks.
- [ ] Dead-man ping from the backup and scrub units on success (healthchecks.io).
- [ ] Acceptance: `zpool offline ark <disk>` produces a notification within one timer
      interval, then `zpool online ark <disk>` and clear it. Do this on a scratch pool if
      you would rather not touch `ark`.

Files: `modules/monitoring.nix` (new), `hosts/hyper/default.nix` (import).

---

## 5. Small correctness fixes (no milestone needed)

- [ ] `hosts/plex/default.nix` opens 32400 to all of VLAN 20 via `allowedTCPPorts`.
      `PLAN.md` §6.4 says edge (10.30.0.0/24) → plex only. Use
      `networking.firewall.extraInputRules` and drop 32400 from `allowedTCPPorts`.
      Same question for port 22 on plex: mgmt only, or every VLAN?
- [ ] Confirm `networking.nameservers = [ "10.10.10.1" ]` actually resolves
      `*.rollenhagen.me` for the guests. If the UDM does not serve those names locally,
      either add them to the UDM's local DNS or set the guests' resolvers explicitly.
- [ ] `services.zfs.autoScrub` only covers `ark` — after adding any second pool, add it to
      `services.zfs.autoScrub.pools` (the default is all pools, verify it stays that way).
- [ ] Nothing pins `boot.kernelPackages`; if ZFS ever lags unstable, that is the one-line
      fix, and the comment in `hosts/hyper/default.nix` already says so.

---

## 6. Deliberately not now

- **GPU passthrough (M8).** GTX 960 / GM206 is 1–2 concurrent 1080p transcodes and is frozen
  on driver 580. Only worth it if CPU transcoding actually annoys you.
- **sops-nix / age secrets.** The flake currently holds zero secrets (Caddy uses HTTP-01).
  Add it the day you want DNS-01, a Plex token, or an API key in the repo.
- **Prometheus + Grafana.** One box, no second machine to watch it from. The alerting in §4
  is the 90% case.
- **More VMs.** The `arr` stack, Nextcloud, whatever — each is a copy of the plex/edge
  pattern, and none of them are worth building before the data is protected.

---

## 7. Untested / needs a real boot to confirm

- [ ] `disko` layout in `hosts/hyper/disko.nix` has been built, not run against the SSD.
- [ ] `virsh define` from the flake path, and `virsh start` for either guest, on real
      hardware.
- [ ] virtiofs mount + the `qemu-libvirtd` group permissions (README §4) on the real
      library.
- [ ] `boot.growPartition` growing the guest root to the full zvol on first boot.
