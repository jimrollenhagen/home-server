# The automation account, on the host and in every guest.
#
# It has exactly the privileges listed in `agentSudo` below, and nothing else.
# Every entry generates both a script at a fixed path and the sudoers line that
# allows it, from one source — sudoers is never edited by hand and there is no
# NOPASSWD: ALL.
#
# The list is deliberately trivial today. Deploying Nix from the agent is a
# later, separately reviewed change (PLAN-agent.md §8); adding an entry here is
# the only way to widen the grant, and it is a root grant.
{ lib, pkgs, net, ... }:
let
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
  imports = [ ./constants.nix ];

  users.users.agent = {
    isNormalUser = true;
    description = "automation";
    # The robot's own key (nothing, until it is generated on the agent VM) plus
    # the human keys, so a broken ssh-agent on the VM is not a lockout.
    openssh.authorizedKeys.keys = net.agentKeys ++ net.adminKeys;
  };

  # Real files at a fixed path. sudo resolves symlinks before matching, so a
  # rule pointing at /run/current-system/sw/bin would never fire.
  system.activationScripts.agent-sudo = installScripts;

  security.sudo.extraRules = [{
    users = [ "agent" ];
    commands = map (c: {
      command = "/usr/local/sbin/agent-${c.name}";
      options = [ "NOPASSWD" ];
    }) agentSudo;
  }];
}
