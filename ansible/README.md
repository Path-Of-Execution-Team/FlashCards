# FlashCards Ansible Provisioning

This directory is the infrastructure-as-code replacement for the one-off
`k8s/provision/provision-dev-node.sh` script.

It converges a single-node Ubuntu VPS into the Kubernetes substrate expected by
the FlashCards manifests:

- k3s `v1.36.2+k3s1`, with bundled Traefik disabled
- Helm `v3.21.3`
- k9s `v0.51.0`, `mc`/`mcedit`, `EDITOR=mcedit` and shell alias `k=kubectl`
- Traefik `41.0.2`
- cert-manager `v1.21.0` and `letsencrypt-production`
- Vault `0.34.0` with the Agent Injector
- PostgreSQL `postgres:18.3-bookworm` in namespace `database`
- Kafka `apache/kafka:4.3.1` in namespace `kafka`
- Kafka UI in namespace `kafka`, protected by Traefik BasicAuth
- the target application namespace
- optional application bootstrap: Vault policies/roles, missing app secrets and
  the `flashcards_user` PostgreSQL role/database

## Run From Your Machine

```bash
python -m pip install -r ansible/requirements.txt
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/provision.yml --limit develop
```

For first bootstrap of a disposable develop node, allow Vault initialisation:

```bash
ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/provision.yml \
  --limit develop \
  -e vault_initialize=true \
  -e vault_unseal_from_node_file=true \
  -e vault_configure_kubernetes_auth=true
```

Vault init output is written only on the node at `/root/vault-init.json` with
mode `0600`. Move it to a password manager and remove it from the server when
you no longer want automated unseal from that file.

When pseudo auto-unseal is enabled, Ansible creates the Kubernetes secret
`vault/vault-auto-unseal` from `VAULT_UNSEAL_KEYS`, `VAULT_UNSEAL_KEY`, or from
`/root/vault-init.json` if the file is still present. `VAULT_UNSEAL_KEYS` may be
newline- or comma-separated; use enough keys for the environment's threshold. A
CronJob then reads that Kubernetes secret and unseals Vault after restarts. This
is intentionally a convenience tradeoff for a single-node setup, not the same
security model as cloud KMS auto-unseal.

## CI Mode

`.github/workflows/provision.yml` runs this playbook over SSH using the same
repository secret and environment variables as deploy:

- `SSH_PRIVATE_KEY`
- `SSH_KNOWN_HOSTS`
- environment vars `SSH_HOST`, `SSH_USER`, `K8S_NAMESPACE`, `PUBLIC_HOST`

The deploy workflow calls it before rendering and applying the app manifests.
CI passes `vault_initialize=false`, so a fresh or sealed Vault fails early
instead of creating secrets during an application deploy.

When `app_bootstrap=true`, the playbook also creates missing application
credentials. It needs either:

- `VAULT_BOOTSTRAP_TOKEN` in the workflow environment, or
- `/root/vault-init.json` still present on the node during first bootstrap.

Optional environment secrets can override the generated first values:

- `VAULT_UNSEAL_KEYS`, used to create `vault/vault-auto-unseal` when the node
  init file has already been removed
- `VAULT_UNSEAL_KEY`, legacy/single-key fallback for one-share environments
- `VAULT_USERPASS_PASSWORD`, used for the `bosman` Vault userpass account
- `KAFKA_UI_BASIC_AUTH_USER`, defaults to `bosman`
- `KAFKA_UI_BASIC_AUTH_PASSWORD`, generated to
  `/root/kafka-ui-basic-auth.txt` if missing
- `FLASHCARDS_DB_PASSWORD`
- `FLASHCARDS_JWT_SECRET`
- `FLASHCARDS_MAIL_USERNAME`
- `FLASHCARDS_MAIL_PASSWORD`

Existing Vault secret paths are left untouched. The PostgreSQL role is always
synced to the password currently stored in Vault.

If `VAULT_USERPASS_PASSWORD` is missing during first bootstrap while
`/root/vault-init.json` is still present, Ansible generates a password and
stores it only on the node at `/root/vault-userpass-bosman.txt` with mode
`0600`. Existing environments where the init file has already been removed
should set `VAULT_USERPASS_PASSWORD` once to create or rotate the user.
