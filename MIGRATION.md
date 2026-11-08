# MIGRATION — moving Hermes from `agent1` into the lab

The agent VM (`agent.apps.rollenhagen.me`, 10.20.0.30) becomes where Hermes lives. Its
identity — config, secrets, memories, skills, session history — moves from
`agent1.jroll.dev`, and the old instance stops.

Read `PLAN-agent.md` §5.1 for why each item is or is not copied. This file is the
executable order, and every step says how to check it.

One constraint shapes the whole thing: `agent1` cannot route to `10.0.0.0/8`, so the copy
is **pulled by the VM**, not pushed from the old host. The VM's `agent` key is already in
`jim`'s `~/.ssh/authorized_keys` on `agent1` for exactly that.

## 0. Preconditions

- [ ] The agent VM boots, `hostname -f` is `agent.apps.rollenhagen.me`, `ip -br addr`
      shows 10.20.0.30, and you can ssh to it from the laptop.
- [ ] All four machines are on a commit that contains the agent key
      (`git log -1` includes `constants: the agent VM's public key`).
- [ ] All four FQDNs resolve from the machine you deploy from — they are the script's
      targets, so a missing record is a failed deploy, not a slow one.
- [ ] `~/server` checkout is clean enough to build: `git status` shows nothing you did not
      mean to deploy.

## 1. Put the key on every machine

On `hyper`, from the checkout, as `jim`:

    scripts/deploy.sh hyper
    scripts/deploy.sh plex
    scripts/deploy.sh edge
    scripts/deploy.sh agent

`hyper` is a local switch; the three guests are built on hyper, copied to `jim@<fqdn>` and
switched. The script derives the FQDN from the configuration (`networking.fqdn`), so
nothing here hardcodes an address.

Because the deploy now originates on the host rather than on the laptop, the UDM Pro has
to permit `10.10.10.10` → TCP 22 on the apps and edge VLANs. If a guest step fails at its
ssh check, that rule is the first thing to look at.

## 2. Prove the agent can reach the others

On the VM, as `agent`:

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@hyper.mgmt.rollenhagen.me true
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@plex.apps.rollenhagen.me true
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@edge.rollenhagen.me true

`StrictHostKeyChecking=accept-new` is deliberate: it populates `~/.ssh/known_hosts` once,
so later unattended runs do not hang on a prompt. Expect this to succeed and
`ssh agent@<host> sudo -n true` to fail — the agent has no deploy rights yet.

If a host is unreachable, it is the UDM Pro rule (`10.20.0.30` → TCP 22 on
`10.10.10.10` and `10.30.0.10`), not the guest firewall: `plex` is on the same bridge, and
the agent's own sshd only accepts the management and client subnets.

## 3. Install Hermes on the VM

As `agent`:

    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    hermes --version
    ls ~/.hermes

The installer creates `~/.local/bin/hermes` and a fresh `~/.hermes`; step 4 overwrites the
state in it. Nothing from the old host is needed to get this far.

## 4. First copy — while the old gateway is still running

From the VM, as `agent`:

    rsync -aHAX --info=progress2 \
      -e 'ssh -o StrictHostKeyChecking=accept-new' \
      --exclude cache --exclude installs --exclude tools --exclude hermes-agent \
      --exclude logs --exclude audio_cache --exclude image_cache --exclude telemetry \
      --exclude models_dev_cache.json \
      jim@agent1.jroll.dev:/home/jim/.hermes/ /home/agent/.hermes/

    chmod 600 ~/.hermes/.env ~/.hermes/auth.json

What the exclusions are: `cache/` (294 MB), `installs/` (120 MB), `tools/` (1.5 GB) and
`hermes-agent/` (572 MB) are all rebuilt by the installer on first use; `logs/` and the
media caches are not state; `models_dev_cache.json` is a model catalogue cache. Everything
else — `config.yaml`, `.env`, `auth.json`, `SOUL.md`, `memories/`, `skills/`, `plugins/`,
`hooks/`, `cron/`, `state.db*`, `kanban.db*`, `projects.db`, `backups/` — comes across.

This pass runs with the old gateway live, so `state.db` may be a few seconds stale. Step 5
fixes that; do not treat this copy as final.

    hermes doctor
    hermes chat -q "hostname"        # expect: agent

## 5. Cutover

Run this from the VM's shell, not from an `agent1` CLI session — stopping the gateway ends
whatever client is attached to it.

1. Stop the old gateway:

       ssh jim@agent1.jroll.dev 'hermes gateway stop'
       ssh jim@agent1.jroll.dev 'test ! -e ~/.hermes/gateway.pid && echo stopped'

2. Re-run the step 4 `rsync` verbatim. The second pass is quick and picks up the final
   `state.db` write plus the write-ahead file.

3. Start Hermes on the VM, as `agent`:

       hermes

   Under `herdr` if you want it to survive a dropped ssh session (herdr is installed on
   every machine by `modules/herdr.nix`).

4. Check it is the same instance, not a fresh one:

       hermes config get model
       ls ~/.hermes/memories
       hermes skills list

**Never run both gateways at once.** They share `auth.json` and `install_id`; with no
messaging platform configured today that is only confusing, but the moment one is added,
one of the two silently loses messages.

## 6. Give the VM the repo

Add `agent@agent`'s public key (`~/.ssh/id_ed25519.pub` on the VM) to GitHub as a **deploy
key with write access** on `jimrollenhagen/home-server`. Then, on the VM:

    git clone git@github.com:jimrollenhagen/home-server.git
    cd home-server && git log --oneline -3

Write access is the point: the agent edits this repo. It still cannot deploy — that is the
separate, deliberately deferred capability in `PLAN-agent.md` §8 — so a push changes
nothing until you run `scripts/deploy.sh`.

## 7. Retire the old instance

- Keep `agent1` powered off (not destroyed) for a week.
- Rollback until then: power `agent1` back on and run `hermes` there; its state is
  untouched by the copy.
- After a week: destroy it. It is the only copy of nothing — the state is on the VM and the
  config is in git.

## 8. After the move

- Deploys are `scripts/deploy.sh <host>`, from the VM or the laptop, as `jim`.
- The agent can build and push but not activate anything: `sudo -l -U agent` shows exactly
  `/usr/local/sbin/agent-echo`.
- When you want it to deploy, that is a new plan (wrapper, `trusted-users`, rollback), not
  an edit to this one.
