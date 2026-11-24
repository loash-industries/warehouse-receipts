#!/usr/bin/env bash
# One-shot harness: world-contracts localnet (dev) + multicoin + warehouse_receipts v1,
# then the evaluation suite. Report: harness/out/report.json
#
#   ./run.sh            reuse a running localnet; deploy wr if not deployed yet
#   ./run.sh --fresh    restart the localnet from genesis and redeploy everything
#   ./run.sh --down     stop the localnet
set -euo pipefail
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WC="${WC:-$(cd "$HARNESS/../../../world-contracts" && pwd)}"
LOCALNET="$WC/agentictools/skills/localnet-integration/run.sh"

case "${1:-}" in
  --down) exec "$LOCALNET" down ;;
  --fresh) "$LOCALNET" down || true; rm -f "$HARNESS/out/wr.localnet.json"; shift ;;
esac

if ! docker ps -q -f "name=^world-localnet$" | grep -q .; then
  echo "[wr-harness] world-contracts @ $(git -C "$WC" rev-parse --short HEAD) ($(git -C "$WC" branch --show-current)) -> localnet"
  "$LOCALNET" up
  rm -f "$HARNESS/out/wr.localnet.json"
fi
[ -f "$HARNESS/out/wr.localnet.json" ] || "$HARNESS/scripts/deploy.sh"

# The localnet container installs Linux node_modules into world-contracts; restore host ones.
PNPM="${PNPM:-pnpm}"
(cd "$WC" && "$PNPM" --version >/dev/null 2>&1) || PNPM="$HOME/.cache/node/corepack/v1/pnpm/$(jq -r '.packageManager|split("@")[1]' "$WC/package.json")/pnpm"
(cd "$WC" && "$PNPM" install --frozen-lockfile >/dev/null)
ln -sfn "$WC/sdk/world-sdk/node_modules" "$HARNESS/ts/node_modules"

ACCOUNTS="$WC/docker/genesis/accounts.json"
cd "$HARNESS/ts"
SUI_PRIVATE_KEY="$(jq -r .accounts.ADMIN.privateKey "$ACCOUNTS")" \
WORLD_ADMIN_ADDRESS="$(jq -r .accounts.ADMIN.address "$ACCOUNTS")" \
  "$WC/sdk/world-sdk/node_modules/.bin/vitest" run --config vitest.config.ts "$@"
