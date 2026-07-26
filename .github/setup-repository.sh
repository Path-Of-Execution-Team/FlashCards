#!/usr/bin/env bash
#
# One-time GitHub configuration for the FlashCards deploy pipeline.
#
# Creates the `production` and `develop` Environments with their variables, sets
# the repository-level secrets and variables that .github/workflows/deploy.yml
# reads, and installs the dispatch token in the three subproject repositories.
#
# SECRETS: nothing is hard-coded here and nothing is written to disk. The SSH key
# is read from a file you name, the tokens are read from a terminal prompt
# with echo off, and each value is piped to `gh secret set` on stdin so it never
# appears in your shell history or in the process list.
#
# Prerequisites:
#   gh auth login          # needs scopes: repo, admin:repo_hook, read:org
#   ssh access to both nodes (only used to read their public host keys)
#
# Usage:
#   bash .github/setup-repository.sh
#
# Re-running is safe: every call is an upsert.
#
set -euo pipefail

ROOT_REPO="Path-Of-Execution-Team/FlashCards"
SUB_REPOS=(
  "Path-Of-Execution-Team/FlashCardsBackend"
  "Path-Of-Execution-Team/FlashCardsGUI"
  "Path-Of-Execution-Team/FlashCardsHostedServices"
)

PROD_HOST="57.129.66.163"
DEV_HOST="57.128.251.9"
SSH_USER="ubuntu"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

log()  { printf '\n\033[1m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "not logged in - run: gh auth login"
gh repo view "$ROOT_REPO" >/dev/null 2>&1 \
  || die "cannot read $ROOT_REPO - does your token have repo scope?"

# -----------------------------------------------------------------------------
# Host keys. Public data, so this is a variable rather than a secret: GitHub
# masks secrets in logs, which would turn any ssh debug output into ***.
#
# The scan is compared against your own known_hosts when possible, so a MITM at
# scan time cannot quietly install its own key as trusted.
# -----------------------------------------------------------------------------
log "Collecting SSH host keys"
known_hosts=""
for h in "$PROD_HOST" "$DEV_HOST"; do
  scanned=$(ssh-keyscan -t ed25519,rsa -T 10 "$h" 2>/dev/null | grep -v '^#' || true)
  [ -n "$scanned" ] || die "ssh-keyscan got nothing from $h"

  if [ -f "$HOME/.ssh/known_hosts" ] && ssh-keygen -F "$h" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    while read -r _ ktype kdata; do
      local_key=$(ssh-keygen -F "$h" -f "$HOME/.ssh/known_hosts" 2>/dev/null \
        | grep -v '^#' | awk -v t="$ktype" '$2==t {print $3}')
      if [ -n "$local_key" ] && [ "$local_key" != "$kdata" ]; then
        die "$h $ktype does not match your known_hosts - investigate before continuing"
      fi
    done <<< "$scanned"
    echo "  $h: verified against your known_hosts"
  else
    echo "  $h: not in your known_hosts, using the scan as-is"
    ssh-keygen -lf <(printf '%s\n' "$scanned") | sed 's/^/    /'
  fi
  known_hosts+="$scanned"$'\n'
done

log "Setting repository variable SSH_KNOWN_HOSTS"
printf '%s' "$known_hosts" | gh variable set SSH_KNOWN_HOSTS --repo "$ROOT_REPO"

log "Setting repository variable GHCR_PULL_USER"
ghcr_pull_user=$(gh api user --jq .login)
gh variable set GHCR_PULL_USER --repo "$ROOT_REPO" --body "$ghcr_pull_user"
echo "  $ghcr_pull_user"

# -----------------------------------------------------------------------------
# Deploy key. The same private key already used by the `ovh` / `ovh2` ssh
# aliases, so no new key needs to be authorised on either node.
# -----------------------------------------------------------------------------
log "Setting repository secret SSH_PRIVATE_KEY"
[ -f "$SSH_KEY" ] || die "$SSH_KEY not found - set SSH_KEY=/path/to/key and re-run"
grep -q 'PRIVATE KEY' "$SSH_KEY" || die "$SSH_KEY does not look like a private key"
if grep -q 'ENCRYPTED' "$SSH_KEY"; then
  die "$SSH_KEY is passphrase-protected; CI cannot use it. Generate a dedicated
       passphrase-less deploy key, append its .pub to ~/.ssh/authorized_keys on
       both nodes, then re-run with SSH_KEY pointing at it."
fi
gh secret set SSH_PRIVATE_KEY --repo "$ROOT_REPO" < "$SSH_KEY"
echo "  from $SSH_KEY"

# -----------------------------------------------------------------------------
# Environments and their variables.
# -----------------------------------------------------------------------------
set_env_vars() {
  local env_name="$1" host="$2" ns="$3" public_host="$4"
  log "Environment: $env_name"
  gh api --method PUT -H "Accept: application/vnd.github+json" \
    "repos/$ROOT_REPO/environments/$env_name" >/dev/null
  gh variable set SSH_HOST       --repo "$ROOT_REPO" --env "$env_name" --body "$host"
  gh variable set SSH_USER       --repo "$ROOT_REPO" --env "$env_name" --body "$SSH_USER"
  gh variable set K8S_NAMESPACE  --repo "$ROOT_REPO" --env "$env_name" --body "$ns"
  gh variable set PUBLIC_HOST    --repo "$ROOT_REPO" --env "$env_name" --body "$public_host"
  echo "  $host  ns=$ns  host=$public_host"
}

set_env_vars production "$PROD_HOST" moomento     moomento.pl
set_env_vars develop    "$DEV_HOST"  moomento-dev dev.moomento.pl

# -----------------------------------------------------------------------------
# Tokens. Read with echo off and piped on stdin, never passed as an argument.
# -----------------------------------------------------------------------------
read_secret() {
  local prompt="$1" value=""
  printf '%s' "$prompt" >&2
  IFS= read -rs value
  printf '\n' >&2
  [ -n "$value" ] || die "empty value"
  printf '%s' "$value"
}

# The PATs cannot be minted through the API, so they have to be typed. When
# this script runs without a terminal (CI, or an agent shell) the prompts are
# skipped rather than silently reading EOF and storing an empty secret.
if [ ! -t 0 ]; then
  log "No terminal - skipping the token prompts"
  cat >&2 <<MSG
  Everything that can be set non-interactively is done. Run this script again
  from a terminal, or set the tokens individually:

    gh secret set GHCR_PULL_TOKEN --repo $ROOT_REPO
    gh variable set GHCR_PULL_USER --repo $ROOT_REPO --body <token-owner-login>
    gh secret set SUBPROJECT_WORKFLOW_TOKEN --repo $ROOT_REPO
$(printf '    gh secret set DEPLOY_DISPATCH_TOKEN --repo %s\n' "${SUB_REPOS[@]}")
MSG
else
  log "GHCR pull token"
  cat >&2 <<'MSG'
  A classic PAT with read:packages ONLY, owned by the GHCR_PULL_USER printed
  above. Used by the deploy workflow to refresh the in-cluster `ghcr-pull`
  secret so the nodes can pull private images.
  Create at: https://github.com/settings/tokens
MSG
  ghcr_token=$(read_secret "  GHCR_PULL_TOKEN: ")
  printf '%s' "$ghcr_token" | gh secret set GHCR_PULL_TOKEN --repo "$ROOT_REPO"
  echo "  set on $ROOT_REPO"

  log "Subproject workflow token"
  cat >&2 <<MSG
  A fine-grained PAT scoped to the three subproject repositories with
  "Actions: read and write" and "Contents: read". The root Deploy workflow uses
  it only when a first deploy needs to build a missing image by running that
  subproject's docker-publish.yml workflow.
  Create at: https://github.com/settings/personal-access-tokens/new
MSG
  subproject_workflow_token=$(read_secret "  SUBPROJECT_WORKFLOW_TOKEN: ")
  printf '%s' "$subproject_workflow_token" | gh secret set SUBPROJECT_WORKFLOW_TOKEN --repo "$ROOT_REPO"
  echo "  set on $ROOT_REPO"

  log "Deploy dispatch token"
  cat >&2 <<MSG
  A fine-grained PAT scoped to $ROOT_REPO with
  "Contents: read and write". Each subproject uses it to tell this repository
  that a new image was published. GITHUB_TOKEN cannot do this - it is scoped to
  the repository it runs in.
  Create at: https://github.com/settings/personal-access-tokens/new
MSG
  dispatch_token=$(read_secret "  DEPLOY_DISPATCH_TOKEN: ")
  for repo in "${SUB_REPOS[@]}"; do
    printf '%s' "$dispatch_token" | gh secret set DEPLOY_DISPATCH_TOKEN --repo "$repo"
    echo "  set on $repo"
  done

  unset ghcr_token subproject_workflow_token dispatch_token
fi

# -----------------------------------------------------------------------------
log "Result"
gh variable list --repo "$ROOT_REPO"
gh secret   list --repo "$ROOT_REPO"
for env_name in production develop; do
  echo "--- $env_name"
  gh variable list --repo "$ROOT_REPO" --env "$env_name"
done

cat <<MSG

Remaining manual steps
----------------------
1. DNS (Cloudflare, SSL/TLS mode Full (strict)). Only the frontend is public,
   so there is one record per environment and no API hostname:
     moomento.pl      A  $PROD_HOST
     www.moomento.pl  CNAME  moomento.pl
     dev.moomento.pl  A  $DEV_HOST
2. Provision the develop node:
     python -m pip install -r ansible/requirements.txt
     ansible-playbook -i ansible/inventory.example.yml ansible/playbooks/provision.yml --limit develop \
       -e vault_initialize=true -e vault_unseal_from_node_file=true -e vault_configure_kubernetes_auth=true
3. Create the develop branch in this repository - deploy.yml checks it out for
   every develop deploy:
     git switch -c develop && git push -u origin develop
4. Commit and push the workflow changes inside each source/* submodule; they are
   separate repositories and CI cannot see them until they are pushed.
5. Optional: add a required reviewer to the production Environment at
     https://github.com/$ROOT_REPO/settings/environments
MSG
