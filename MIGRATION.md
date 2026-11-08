# MIGRATION — moving Hermes from `agent1` into the lab

The agent VM (`agent.apps.rollenhagen.me`, 10.20.0.30) becomes where Hermes lives. Its
identity — secrets, memories, skills, session history — moves from `agent1.jroll.dev`, the
configuration moves into this repo, and the old instance stops.

Read `PLAN-agent.md` §5 for why each item is or is not copied. This file is the executable
order, and every step says how to check it.

Three things shape it:

- `agent1` cannot route to `10.0.0.0/8`, so the copy is **pulled by the VM**. The VM's
  `agent` key is already in `jim`'s `~/.ssh/authorized_keys` on `agent1` for that.
- Hermes is a systemd service from the upstream NixOS module, not a curl install. There is
  no installer step, and the config is `hermes/config.yaml` in this repo.
- The service is `hermes-agent`, runs as `agent`, with `HERMES_HOME=/home/agent/.hermes`.
  That is the same layout the installer used, so the paths below look familiar.

## 0. Preconditions

- [ ] The agent VM boots, `hostname -f` is `agent.apps.rollenhagen.me`, `ip -br addr`
      shows 10.20.0.30, and you can ssh to it from the laptop.
- [ ] All four machines are on a commit that contains the agent key and the Hermes module
      (`git log -1` … `modules/hermes-agent.nix` exists).
- [ ] All four FQDNs resolve from hyper — they are the deploy script's targets, so a
      missing record is a failed deploy, not a slow one.
- [ ] hyper has room for the first build. The Nix package is a uv2nix closure: ~500
      derivations, ~1.5 GiB unpacked, built once here and then cached in the store.

## 1. Put the key on every machine

On `hyper`, from the checkout, as `jim`:

    scripts/deploy.sh hyper
    scripts/deploy.sh plex
    scripts/deploy.sh edge
    scripts/deploy.sh agent

`hyper` is a local switch; the three guests are built on hyper, copied to `jim@<fqdn>` and
switched. The script derives the FQDN from the configuration (`networking.fqdn`), so
nothing here hardcodes an address.

Because the deploy originates on the host rather than the laptop, the UDM Pro has to permit
`10.10.10.10` → TCP 22 on the apps and edge VLANs. If a guest step fails at its ssh check,
that rule is the first thing to look at.

## 2. Prove the agent can reach the others

On the VM, as `agent`:

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@hyper.mgmt.rollenhagen.me true
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@plex.apps.rollenhagen.me true
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new agent@edge.rollenhagen.me true

`StrictHostKeyChecking=accept-new` is deliberate: it populates `~/.ssh/known_hosts` once,
so later unattended runs do not hang on a prompt. Expect this to succeed and
`ssh agent@<host> sudo -n true` to fail — the agent has no deploy rights yet.

If a host is unreachable, it is the UDM Pro rule (`10.20.0.30` → TCP 22 on `10.10.10.10`
and `10.30.0.10`), not the guest firewall: plex is on the same bridge, and the agent's own
sshd only accepts the management and client subnets.

## 3. Stop the old gateway

From the VM's shell — not from an `agent1` CLI session, because stopping the gateway ends
whatever client is attached to it:

    ssh jim@agent1.jroll.dev 'hermes gateway stop'
    ssh jim@agent1.jroll.dev 'test ! -e ~/.hermes/gateway.pid && echo stopped'

This is the only downtime, and it is what makes the copy consistent. If you abandon the
migration here, `hermes` on `agent1` starts it again.

## 4. Stage the state

From the VM, as `agent`:

    rsync -aHAX --info=progress2 \
      -e 'ssh -o StrictHostKeyChecking=accept-new' \
      --exclude config.yaml --exclude cache --exclude installs --exclude tools \
      --exclude hermes-agent --exclude logs --exclude audio_cache --exclude image_cache \
      --exclude telemetry --exclude models_dev_cache.json \
      jim@agent1.jroll.dev:/home/jim/.hermes/ /home/agent/.hermes/

    chmod 600 ~/.hermes/.env ~/.hermes/auth.json

Why the exclusions:

- `config.yaml` — now `hermes/config.yaml` in the repo, installed by the module; a copied
  one would be overwritten at the next activation anyway.
- `cache/` (294 MB), `installs/` (120 MB), `tools/` (1.5 GB), `hermes-agent/` (572 MB) —
  the Nix package replaces all of it.
- `logs/`, `audio_cache/`, `image_cache/`, `telemetry/`, `models_dev_cache.json` — caches,
  not state.

Everything else comes across: `.env`, `auth.json`, `SOUL.md`, `memories/`, `skills/`,
`plugins/`, `hooks/`, `cron/`, `state.db*`, `kanban.db*`, `projects.db`, `backups/`.

The `.hermes` directory does not exist yet — the module creates it at activation — but
rsync creates it, and activation then chowns it to the service user.

## 5. Start it as a service

On hyper:

    scripts/deploy.sh agent

Activation copies `hermes/config.yaml` into `HERMES_HOME`, writes the `.managed` marker
(which is what makes `hermes config set` refuse), chowns `/home/agent/.hermes` to `agent`,
and starts `hermes-agent`.

Check it:

    systemctl status hermes-agent
    journalctl -u hermes-agent -n 50
    hermes --version
    hermes chat -q "hostname"          # expect: agent
    ls ~/.hermes/memories && hermes skills list

If the unit is up but a chat fails, read the journal before touching anything — the usual
cause is a missing API key in `.env`, which step 4 should have brought over.

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
- Rollback until then: power it back on and run `hermes` there; its state is untouched by
  the copy. Do **not** leave both running — they share `auth.json` and `install_id`.
- After a week: destroy it. It is the only copy of nothing — the state is on the VM and the
  config is in git.

## 8. After the move

- Deploys are `scripts/deploy.sh <host>`, on hyper, as `jim`.
- Configuration is `hermes/config.yaml` in this repo. `hermes config set` fails by design;
  edit the file, commit, `scripts/deploy.sh agent`.
- Secrets are still `~/.hermes/.env` on the VM, not in git and not in Nix. Declaring them
  through the module's `environmentFiles` (sops-nix/agenix) is a later step.
- The agent can build and push but not activate anything: `sudo -l -U agent` shows exactly
  `/usr/local/sbin/agent-echo`.
