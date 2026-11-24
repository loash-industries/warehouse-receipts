#!/usr/bin/env bash
# Publish multicoin + warehouse_receipts (v1 port, TRIEX-160) onto the running
# world-contracts localnet, linked against the world packages it deployed.
#
# Prereq: world-contracts localnet up:
#   $WC/agentictools/skills/localnet-integration/run.sh up
#
# Builds inside the same pinned image (sui 1.78) in a sibling container that
# shares world-localnet's network. Uses a COPY of world's ephemeral pubfile with
# its /app paths rewritten to host paths, so world-contracts' files are untouched.
# Writes harness/out/wr.localnet.json.
set -euo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WC="${WC:-$(cd "$HARNESS/../../../world-contracts" && pwd)}"
TRIEX_ROOT="$(cd "$WC/.." && pwd)"
IMAGE="${IMAGE:-world-integration}"
CONTAINER="${CONTAINER:-world-localnet}"
OUT="$HARNESS/out"

log() { echo "[wr-harness] $*"; }
die() { echo "[wr-harness] ERROR: $*" >&2; exit 1; }

docker ps -q -f "name=^${CONTAINER}$" | grep -q . || die "$CONTAINER not running (run.sh up first)"
[ -f "$WC/deployments/localnet/Pub.localnet.toml" ] || die "no world pubfile; is world deployed?"

mkdir -p "$OUT"
sed "s#\"/app/#\"$WC/#g" "$WC/deployments/localnet/Pub.localnet.toml" > "$OUT/Pub.localnet.toml"
ADMIN_KEY="$(jq -r '.accounts.ADMIN.privateKey' "$WC/docker/genesis/accounts.json")"

log "Publishing multicoin + warehouse_receipts against world @ $(git -C "$WC" rev-parse --short HEAD) ($(git -C "$WC" branch --show-current))"
docker run --rm --network "container:$CONTAINER" --entrypoint bash \
  -v "$TRIEX_ROOT:$TRIEX_ROOT" -e ADMIN_KEY="$ADMIN_KEY" -e HARNESS="$HARNESS" -e OUT="$OUT" \
  "$IMAGE" -lc '
set -euo pipefail
mkdir -p /root/.sui && printf "[]" > /root/.sui/sui.keystore
cat > /root/.sui/client.yaml <<EOF
---
keystore:
  File: /root/.sui/sui.keystore
envs:
  - alias: localnet
    rpc: "http://127.0.0.1:9000"
  - alias: testnet
    rpc: "https://fullnode.testnet.sui.io:443"
active_env: localnet
active_address: ~
EOF
sui keytool import "$ADMIN_KEY" ed25519 --alias ADMIN >/dev/null
sui client switch --address ADMIN >/dev/null
for pkg in multicoin warehouse_receipts_v1; do
  echo "[wr-harness] test-publish $pkg"
  (cd "$HARNESS/move/$pkg" && sui client test-publish --build-env testnet \
     --pubfile-path "$OUT/Pub.localnet.toml" --json > "$OUT/$pkg.publish.json")
done
'

pkg_id() { jq -r '.objectChanges[] | select(.type=="published") | .packageId' "$OUT/$1.publish.json"; }
obj_id() { jq -r --arg t "$2" '.objectChanges[] | select(.type=="created" and (.objectType|endswith($t))) | .objectId' "$OUT/$1.publish.json"; }

for f in multicoin warehouse_receipts_v1; do
  status=$(jq -r '.effects.status.status // .effects.V2.status // "unknown"' "$OUT/$f.publish.json" 2>/dev/null || echo unknown)
  [ "$status" = "success" ] || die "$f publish status: $status (see $OUT/$f.publish.json)"
done

MC=$(pkg_id multicoin); WR=$(pkg_id warehouse_receipts_v1)
REG=$(obj_id warehouse_receipts_v1 "::vault::VaultRegistry")
jq -n --arg mc "$MC" --arg wr "$WR" --arg reg "$REG" \
  --arg world "$(git -C "$WC" rev-parse HEAD)" \
  '{multicoin: $mc, warehouseReceipts: $wr, vaultRegistry: $reg, worldContractsRev: $world}' \
  > "$OUT/wr.localnet.json"
log "multicoin          $MC"
log "warehouse_receipts $WR"
log "VaultRegistry      $REG"
log "Manifest: $OUT/wr.localnet.json"
