# Hermes runs as the `agent` systemd service on the agent VM, from the upstream
# NixOS module rather than the curl installer: no venv drift, a hardened unit,
# restart on boot, and config that comes from this repo.
#
# Imported by hosts/agent only. Everything else in the lab has no business
# running an agent.
{ inputs, ... }:
{
  imports = [ inputs.hermes-agent.nixosModules.default ];

  services.hermes-agent = {
    enable = true;

    # The account already exists (modules/agent-access.nix) and holds the key to
    # the rest of the lab, so the service runs as it instead of a second
    # `hermes` user that would own nothing.
    user = "agent";
    group = "users";
    createUser = false;

    # The module sets HOME to stateDir for the service, not to the user's passwd
    # home. Pointing it at the agent's home is what lets ssh and git see
    # /home/agent/.ssh and the checkout; HERMES_HOME becomes
    # /home/agent/.hermes, the same layout the standard installer produced.
    stateDir = "/home/agent";

    # config.yaml is versioned here and copied to HERMES_HOME on every
    # activation. Consequence: `hermes config set` is refused (the module writes
    # a `.managed` marker), so a setting change is an edit here plus
    # `scripts/deploy.sh agent`. Secrets are NOT in this file.
    configFile = ../hermes/config.yaml;

    # Puts the CLI on PATH and exports HERMES_HOME system-wide, so an
    # interactive `hermes` shares state with the gateway instead of making a
    # second ~/.hermes.
    addToSystemPackages = true;
  };

  # Cron jobs run in `systemd-run --user` scopes, which need a user manager for
  # the service uid. The module only enables lingering when it creates the user.
  users.users.agent.linger = true;
}
