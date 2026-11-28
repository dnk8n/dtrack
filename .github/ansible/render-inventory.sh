#!/usr/bin/env bash
# Render the Ansible inventory for the scheduled workflows from repository
# variables, so no deployment's hostnames are committed. A group is only
# written when its host is set; playbooks then simply match no hosts.
#   PROD_HOST     host that is backed up and has its keys rotated
#   RESTORE_HOST  host that receives the continuous test restore
set -euo pipefail

cat <<'INI'
[all:vars]
ansible_ssh_user=ubuntu
ansible_ssh_private_key_file=private_key
ansible_ssh_common_args='-o UserKnownHostsFile=known_hosts -o ServerAliveInterval=60 -o ServerAliveCountMax=5'
INI

if [ -n "${PROD_HOST:-}" ]; then
    printf '\n[prod_server]\n%s\n' "$PROD_HOST"
fi
if [ -n "${RESTORE_HOST:-}" ]; then
    printf '\n[test_server]\n%s\n' "$RESTORE_HOST"
fi
