# PLAN — agent VM, lab-wide herdr, and a machine account for updates

Status: implemented. Config in `0572ef9`, the hyper-side helper in `27f1eae`. The three
questions from review are settled (§1.1–1.3); §1.4 lists what it rests on. What has not
been exercised is anything that needs the lab: the zvol, the image, first boot, and the
copy of Hermes (§4–§5).

## 0. What this adds

An 8 GiB NixOS guest on `hyper` named `agent` on VLAN 20, which is where Hermes lives from
now on. It gets:

- its own ed25519 key, generated on the guest, never in git;
- an `agent` account on **every** machine (hyper, plex, edge, agent), with one allowlisted
  privileged command — `echo`, today. No deploy rights yet; the framework that will carry
  them is in place and empty on purpose;
- `herdr` as a system package on every machine;
- the current Hermes state — config, `.env`, OAuth tokens, memories, skills, cron,
  kanban, session DB — copied over ssh, then the old instance stopped.

The point is not that the agent can run commands. It is that a machine, not a laptop
session, holds the identity, so the work survives closing the terminal.

## 1. Decisions from review

### 1.1 The name: `agent.apps.rollenhagen.me`

Settled. `rollenhagen.home` was a slip — every machine in `modules/constants.nix` is
`<host>.<vlan>.rollenhagen.me`, and both the DigitalOcean zone and Caddy's certificates are
built around `rollenhagen.me`. A second internal zone would have meant split-horizon
reasoning for no benefit. `agent.apps` mirrors `plex.apps` exactly: one line in constants,
one record on the UDM Pro's local resolver.

### 1.2 The VLAN: `br20`, and what it gives up

The agent sits on `br20` at `10.20.0.30`, next to plex. That is a real cost, taken
deliberately: plex is the only VM exposed to the internet through Caddy, the agent is the
machine that will hold the lab's keys, and a shared bridge means a plex compromise is one
hop from it with no router in between.

The alternative — management VLAN with its own bridge — is the more correct plane, but
`vlan10` carries hyper's own address and there is no `br10`. Adding one means moving the
host's management IP onto the bridge, which is the one change in this repo that can strand
the box. Not worth it for this. What the plan does instead (§3.3):

- restrict the agent's sshd to the management network and your LAN, so the plex path ends
  at a port it cannot authenticate to;
- keep the name in the UDM Pro's local resolver only. `plex.apps` and `hyper.mgmt` are
  already published in the public zone with RFC1918 answers; there is no reason to add a
  third internal address to it;
- router rules shrink to agent→edge (VLAN 30) and agent→hyper (VLAN 10). agent→plex needs
  nothing — and is the one path that can no longer be filtered at the router.

If a management-plane VM ever shows up, `br10` gets its own plan.

### 1.3 Sudo: a framework, no privileges yet

Your call in review: the agent gets **no** deploy rights for now. Deploys stay manual —
you, from the laptop, exactly as in README §7 — until the automation is written and
reviewed as its own change. What this plan installs is the *shape* of the grant, with one
demonstration command in it.

The shape is a list in `modules/agent-access.nix`. Each entry generates, from one source,
a real script at `/usr/local/sbin/agent-<name>` and the matching `sudoers` line for user
`agent`:

```nix
agentSudo = [
  { name = "echo"; script = ''exec ${pkgs.coreutils}/bin/echo "$@"''; }
];
```

Today that is the whole grant. `sudo /usr/local/sbin/agent-echo hi` works; `sudo bash`,
`sudo /bin/echo`, `sudo systemctl` do not. Adding a capability later is one list entry plus
a rebuild — there is no `NOPASSWD: ALL` anywhere, and nobody hand-edits sudoers.

Three constraints, so the framework cannot quietly become more than it says:

- **No `trusted-users` yet.** A Nix trusted user can push arbitrary paths into the store
  and pass options to the daemon as root — strictly more power than the echo command, and
  the reason it is absent here. It belongs in the commit that adds deploy, not before.
- **Scripts are real files at `/usr/local/sbin`**, not `/run/current-system/sw/bin`
  symlinks: sudo resolves symlinks before matching, so a `writeShellScriptBin` rule never
  fires.
- **`agent` stays out of `wheel`.** `security.sudo.wheelNeedsPassword = false` repo-wide,
  so wheel membership is unrestricted passwordless root. `extraRules` is the whole grant.

What the real capability will look like when you want it: an `agent-activate <store-path>`
script that validates a NixOS closure, plus `trusted-users` so it can receive the closure
over ssh, plus the deploy script. That is a root grant on every target and deserves its own
review — §8.

### 1.4 Confirmations

- **RAM:** 32 GiB on hyper — confirmed. plex 8, edge 2, agent 8 puts fixed allocations at
  ~20 GiB. Comfortable.
- **Running Hermes as `agent` on the agent VM** (rather than as `jim`) — one identity
  everywhere, and `jim` stays the human key. `config.yaml` has no `/home/jim` paths in it,
  so the move is a copy, not a rewrite. This plan assumes it.
- **Keep `agent1.jroll.dev` powered off for a week** after cutover, then destroy it.

## 2. Target state

| host  | FQDN                          | VLAN | address      | RAM  | disk        |
|-------|-------------------------------|------|--------------|------|-------------|
| hyper | hyper.mgmt.rollenhagen.me     | 10   | 10.10.10.10  | —    | ext4 + ark  |
| agent | agent.apps.rollenhagen.me     | 20   | 10.20.0.30   | 8 GiB| 64 G zvol   |
| plex  | plex.apps.rollenhagen.me      | 20   | 10.20.0.20   | 8 GiB| 64 G zvol   |
| edge  | edge.rollenhagen.me           | 30   | 10.30.0.10   | 2 GiB| 32 G zvol   |

`agent` is BIOS/GRUB like the other guests, 4 vCPU, no virtiofs, serial console on
`ttyS0`, VNC on `127.0.0.1` for the first boot.

## 3. Repository changes

### 3.1 `modules/constants.nix`

```nix
agent = { address = "10.20.0.30"; prefix = 24; domain = "apps.rollenhagen.me"; };
```

### 3.2 `hosts/hyper/default.nix`

- `vlans`, `bridges` and host addressing: **unchanged.** `br20` already exists and is
  already in `virtualisation.libvirtd.allowedBridges`.
- `nix.settings.trusted-users`: **unchanged** (unset). Adding `agent` there is a root
  grant, so it arrives with the deploy capability, not with the account.
- the `libvirt-domains` oneshot gains `virsh define`/`autostart agent`.

### 3.3 `hosts/agent/default.nix`

New guest config, ~20 lines:

```nix
{ config, lib, pkgs, net, ... }:
{
  networking.hostName = "agent";
  networking.domain = net.agent.domain;

  networking.interfaces.eth0.ipv4.addresses = [
    { inherit (net.agent) address; prefixLength = net.agent.prefix; }
  ];
  networking.defaultGateway = "10.20.0.1";

  # guest.nix opens 22 to the world. This machine holds the lab's key, so only the
  # management network and the client LAN may reach sshd (the laptop is on
  # 192.168.1.0/24). mkForce because the list merges rather than replaces.
  #
  # extraCommands, not extraInputRules: the latter is declared only by the
  # nftables firewall backend, and networking.nftables.enable is false here, so
  # it is a silent no-op. extraCommands is the iptables hook, and it is
  # appended before the final reject.
  networking.firewall.allowedTCPPorts = lib.mkForce [];
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport 22 -s 10.10.10.0/24 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport 22 -s 192.168.1.0/24 -j nixos-fw-accept
  '';

  # The workstation for the flake: nix, git, ssh, and enough tooling to build.
  environment.systemPackages = with pkgs; [ git nix-output-monitor openssh ];

  # Building a NixOS closure needs more store than a service guest.
  nix.settings.auto-optimise-store = true;
}
```

`modules/guest.nix` already supplies sshd, the firewall, flake support, weekly GC and
`wheelNeedsPassword = false`. `agent` needs no extra services.

### 3.4 `hosts/agent/domain.xml`

Copy `hosts/plex/domain.xml`, then: name `agent`, description "lab control — VLAN 20
(apps), 10.20.0.30", `<memory>8</memory>`/`<currentMemory>8</currentMemory>`, 4 vcpu, no
second disk, no `<filesystem>` block, NIC MAC `52:54:00:00:20:30` on `br20`, disk
`/dev/zvol/ark/vm/agent-os`. Keep the `<uuid>`, the serial console, the guest-agent
channel and the VNC-on-loopback block exactly as they are. I will pin a fresh UUID at
write time (not before — a UUID in a document that gets copied twice is a support case).

The pinned-uuid rule from README §7 applies: without it `virsh define` fails with
`already exists with uuid …`.

### 3.5 `modules/keys.nix` — split the two identities

Today it hardcodes `users.users.jim`. Restructure into `net.adminKeys` (jim's two
existing keys, unchanged) and `net.agentKeys` (the robot's public key, added in §4 step 4).

### 3.6 New `modules/agent-access.nix`, imported by the host and every guest

```nix
{ config, lib, pkgs, net, ... }:
let
  # One entry = one /usr/local/sbin/agent-<name> script + one sudoers line.
  # Deliberately trivial: the deploy capability is a later, separately reviewed change.
  agentSudo = [
    {
      name = "echo";
      script = ''exec ${pkgs.coreutils}/bin/echo "$@"'';
    }
  ];

  installScripts = lib.concatMapStrings (c: ''
    install -m 0755 ${pkgs.writeShellScript "agent-${c.name}" c.script} \
      /usr/local/sbin/agent-${c.name}
  '') agentSudo;
in
{
  users.users.agent = {
    isNormalUser = true;
    description = "automation";
    openssh.authorizedKeys.keys = net.agentKeys ++ net.adminKeys;
  };

  # Real files at a stable path — see §1.3 on sudo and symlinks.
  system.activationScripts.agent-sudo = installScripts;

  security.sudo.extraRules = [{
    users = [ "agent" ];
    commands = map (c: {
      command = "/usr/local/sbin/agent-${c.name}";
      options = [ "NOPASSWD" ];
    }) agentSudo;
  }];
}
```

No `trusted-users` here, and no `nixos-rebuild` anywhere. Adding an entry to `agentSudo` is
the only way to widen the grant, and it is a code change in this repo.

Acceptance test for the framework itself, on any machine:

```
sudo -l -U agent                       # exactly one command: /usr/local/sbin/agent-echo
sudo -u agent /usr/local/sbin/agent-echo ok    # → ok
sudo -u agent sudo -n /bin/echo ok     # → "a password is required" (rule is the wrapper)
```

### 3.7 New `modules/herdr.nix`

```nix
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.herdr ];
}
```

`herdr` is in nixpkgs-unstable at 0.9.5 — the same version already running here — so no
flake input and no Rust build of our own. It is one binary, mouse-and-keyboard TUI, no
daemon, no port, no config required; `~/.config/herdr-app/` is per-user and stays out of
Nix. Installing it on `hyper` and the three guests is what lets the laptop's herdr attach
to each machine over ssh and show every pane in one window.

### 3.8 No deploy script yet

There is nothing to write here until the capability exists. Deploys stay exactly as they
are today (`nixos-rebuild switch --flake .#plex --target-host jim@10.20.0.20
--use-remote-sudo`, from the laptop), and rollback stays the boot menu on hyper. The
`agent-activate` wrapper, `trusted-users` and a `scripts/deploy.sh` are §8.

## 4. Build and install order

Order matters: keys and the account land before the VM that uses them, and the VM exists
before anything is copied into it.

1. **Repo commit 1 — plumbing.** constants, keys refactor, `agent-access.nix`,
   `herdr.nix`. No guest yet. `nix build
   .#nixosConfigurations.{hyper,plex,edge}.config.system.build.toplevel` to confirm
   nothing broke (nix-portable here; that build path is known to work).
2. **Deploy plumbing** to hyper, plex, edge (jim's existing path from the laptop:
   `nixos-rebuild switch --flake .#plex --target-host jim@10.20.0.20 --use-remote-sudo`).
   Verify `getent passwd agent` and `sudo -l -U agent` on each.
3. **Repo commit 2 — the guest.** `flake.nix` (`mkGuest "agent" true`,
   `packages.agent-image`), `hosts/agent/{default.nix,domain.xml}`, and the hyper changes
   from §3.2 (define/autostart agent).

   ```
   nix build .#agent-image --out-link result-agent     # on hyper
   sudo zfs create -V 64G ark/vm/agent-os
   sudo qemu-img convert -O raw result-agent/*.qcow2 /dev/zvol/ark/vm/agent-os
   sudo systemctl restart libvirt-domains
   sudo virsh start agent && sudo virsh console agent
   ```

   First boot: log in as `jim` / `changeme`, `passwd`, confirm `ip -br addr` shows
   `10.20.0.30`, and reach it from the laptop (`ssh jim@10.20.0.30`). plex is on the same
   bridge, so also confirm `ssh jim@10.20.0.20` and `ssh jim@10.10.10.10` still work.

   Then on the UDM Pro: a local A record `agent.apps.rollenhagen.me` → `10.20.0.30` (local
   resolver only, not the public zone), and permit `10.20.0.30` → TCP 22 on `10.10.10.10`
   and `10.30.0.10`. Nothing for plex — same bridge.
4. **Key and framework check.** On the agent VM, as `agent`:
   `ssh-keygen -t ed25519 -C agent@agent.apps.rollenhagen.me -f ~/.ssh/id_ed25519 -N ''`.
   Add the public key to `net.agentKeys`, commit, deploy to all four machines. Verify
   `ssh agent@10.10.10.10 true` and `ssh agent@10.20.0.20 true` from the agent VM, and
   `ssh agent@10.20.0.30 true` from the laptop. Then run the §3.6 acceptance test on each
   machine: one sudo line, `agent-echo` works, `/bin/echo` does not.
5. **Git identity for the agent.** Add the same public key to GitHub as a deploy key on
   `jimrollenhagen/home-server` with write access, then `git clone` on the agent VM.
   (Write access is deliberate: the agent edits this repo and cannot deploy it — pushing
   is the only write path it has, and merging still needs you.)
6. **Herdr.** Nothing to do beyond step 1 — but confirm on each machine:
   `ssh <host> herdr --version` → `herdr 0.9.5`. Then add the four as saved SSH machines
   in the laptop's herdr.
7. **Hermes.** §5.
8. **Cutover.** §5.4.

## 5. Moving Hermes

The executable order — with the commands and the checks at each step — is `MIGRATION.md`.
What follows is the reasoning.

### 5.1 What comes, what does not

`~/.hermes` is 2.4 GB here, but almost all of it is rebuildable.

| copy | why |
|---|---|
| `config.yaml` | 132 KB, the whole configuration. No `/home/jim` paths in it. |
| `.env`, `auth.json` | API keys and OAuth tokens. Secrets — ssh only, `chmod 600`, never git. |
| `SOUL.md` | identity/persona. |
| `memories/` | 12 KB. |
| `skills/` | 4 MB — including the homelab build skill and the curator ledger. |
| `plugins/`, `hooks/` | 60 KB. `herdr-agent-state` is configured in `config.yaml`. |
| `cron/` | 40 KB, executions DB. No jobs currently scheduled. |
| `state.db` (+ `-wal`, `-shm`), `kanban.db*`, `projects.db` | sessions, kanban, projects. |
| `backups/` | 1.1 MB. Cheap; keeps the version history. |

| skip | why |
|---|---|
| `cache/` 294 MB, `installs/` 120 MB, `tools/` 1.5 GB, `hermes-agent/` 572 MB | installer and first-run rebuild all of it |
| `logs/`, `audio_cache/`, `image_cache/`, `telemetry/` | not state |

### 5.2 On the agent VM

```
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

as `agent` (creates `~/.local/bin/hermes` and `~/.hermes`), then overwrite `~/.hermes`
with the copy. Run `hermes doctor` and `hermes config get model` before trusting it.

### 5.3 The copy

Gateway stopped on the source first (§5.4), then from `agent1`:

```
rsync -aHAX --info=progress2 \
  ~/.hermes/config.yaml ~/.hermes/.env ~/.hermes/auth.json ~/.hermes/SOUL.md \
  ~/.hermes/memories ~/.hermes/skills ~/.hermes/plugins ~/.hermes/hooks \
  ~/.hermes/backups ~/.hermes/cron ~/.hermes/state.db* ~/.hermes/kanban.db* \
  ~/.hermes/projects.db \
  agent@10.20.0.30:/home/agent/.hermes/
```

Then on the VM: `chmod 600 ~/.hermes/.env ~/.hermes/auth.json`, and
`chown -R agent:users ~/.hermes` (the rsync already preserves ownership by name, but
check it).

### 5.4 Cutover, in this order

1. `hermes gateway stop` on `agent1`; confirm `gateway.pid` is gone.
2. Copy (§5.3), `hermes doctor`, then `hermes chat -q "hostname"` on the VM — expect
   `agent`.
3. Confirm memories and skills are present (`ls ~/.hermes/memories`,
   `hermes skills list`).
4. Leave `agent1` running but with no gateway for a week. **Do not run both**: they share
   `auth.json` and `install_id`, and the moment a messaging platform is added, two
   gateways with one identity means one of them silently loses messages.
5. After a week with the VM up and Hermes working: power off and destroy `agent1`.

Optional, only if you want the agent reachable when you are not ssh'd in: a
`systemd.services.hermes-gateway` unit as `agent` with `Restart=always`. Not included
above — today the gateway only exists to idle-serve this CLI, and no messaging platform is
configured (`channel_directory.json` is empty).

## 6. What the agent can and cannot do afterwards

- Run the allowlisted command: **yes**, `agent-echo`, on all four machines. That is the
  entire sudo surface.
- Build a machine's closure from the flake to check it compiles: **yes**, as an ordinary
  user. Activate it: **no** — no `nixos-rebuild`, no `switch-to-configuration`, no
  `trusted-users`.
- Run arbitrary root commands, install packages, edit `/etc`, read `/etc/shadow`: **no**.
  `sudo -l` shows one line.
- Edit, commit and push this repo: **yes**, via its deploy key. Deploying what it pushed
  still takes you.
- Reach the machines over ssh as `agent`: yes, key only, no sudo. Useful for reading state
  and for herdr panes. agent→plex is the same bridge and needs nothing; agent→edge
  (`10.30.0.10`) and agent→hyper (`10.10.10.10`) need 22 permitted on the UDM Pro. Today's
  guests and host accept 22 from anywhere, so this is a router rule, not a NixOS one —
  **the most likely thing to bite on day one**, and not in this repo.
- Add capability later: one entry in `agentSudo` (§3.6). The first real one is deploy,
  and it is a root grant.

## 7. Risks, plainly

1. **The agent shares `br20` with plex.** The only VM exposed to the internet is one hop
   from the key that owns the lab, and that hop is not filterable at the router. Mitigated,
   not solved, by sshd on the agent accepting only `10.10.10.0/24` and `192.168.1.0/24`
   (§3.3). If that ever feels too thin, the fix is `br10` and its own plan.
2. **The lab now runs the agent that maintains the lab.** If hyper is down, Hermes is
   down with it. That is the trade for "control of the lab" and it is why `agent1` stays
   around for a week.
3. **The framework is where the power will arrive later.** Today the only sudo entry is
   `echo`, so the blast radius is nothing. The risk is that adding a capability becomes
   routine: each one is a short script with `NOPASSWD`, and the deploy entry will also need
   `trusted-users`, which is root by another name. Review that commit as a root grant,
   because it is one.
4. **Secrets cross the LAN.** ssh transport, `0600` on arrival, no copies in git or the
   Nix store. If you want them at rest outside `agent1` as well, that is a `sops`/`age`
   change and a separate plan.
5. **64 G on the agent VM** holds the flake checkout plus one or two closures. Weekly GC
   at 14 days is already configured; if a build of all four machines is ever needed at
   once, watch `df`.

## 8. Not in this plan

- VM backups, snapshots of `agent-os`. The VM is disposable: config is in git, state is
  the `~/.hermes` copy. If it dies, rebuild and re-copy.
- A persistent Hermes gateway service (§5.4).
- `sops`/`age` for the secrets in the repo.
- The deploy automation: `agent-activate`, `trusted-users = [ "agent" ]` on each target,
  and `scripts/deploy.sh`. Its own plan, reviewed as the root grant it is. Until then the
  agent can write and push config but not apply it.
- Adding the agent to `libvirtd` or giving it `virsh`. Same story: one `agentSudo` entry
  scoped to the commands actually wanted, not `NOPASSWD` on `virsh`.
- Any alerting or backup work — that is `TODO.md` M7 and still open.
