# Ansible Preflight

This directory contains a minimal Ansible setup for validating whether a host is ready for the FlashCards stack.

## Structure

- `ansible.cfg` - local Ansible defaults for this repository
- `inventory/hosts.ini` - example inventory
- `group_vars/all.yml` - shared lists of required tools and dependencies
- `playbooks/preflight.yml` - host validation playbook

## What The Playbook Checks

- whether the current user has `sudo` access
- whether `docker`, `kubectl`, and `helm` are available
- whether `PostgreSQL`, `Grafana`, `Promtail`, `Loki`, and `Prometheus` are installed via common binaries

## Usage

From this directory:

```bash
ansible-playbook playbooks/preflight.yml
```

To target another machine, replace `localhost` in `inventory/hosts.ini` with your host or hosts.
