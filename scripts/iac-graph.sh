#!/usr/bin/env bash
# Compiles the IaC graph with every JELLYFIN_SOURCE_* host credential removed,
# so no source-project secret reaches the graph or any argument built from it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset_args=()
for name in $(compgen -e); do
  if [[ "${name}" == JELLYFIN_SOURCE_* ]]; then unset_args+=(-u "${name}"); fi
done
cd "${root}"
env "${unset_args[@]}" ./node_modules/.bin/railway-iac-ts .railway/railway.ts </dev/null
