#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUSTOMIZE_PATH="${1:-$SCRIPT_DIR}"

echo "Applying monitoring resources from $KUSTOMIZE_PATH"
"$KUBECTL_BIN" apply -k "$KUSTOMIZE_PATH"
