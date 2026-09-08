#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ensure-network.sh — idempotently provision the shared proxy network.
#
# The network is declared `external: true` in docker-compose.yml (simple,
# predictable lifecycle: `docker compose down` never destroys it), so it must
# exist before `up`. This script:
#   * reads PROXY_NETWORK / PROXY_SUBNET from .env when present
#   * adopts the network if it already exists (any subnet)
#   * otherwise creates it with the configured subnet (or Docker's default
#     pool when no subnet is configured)
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out.sh"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
out() { "$OUT" "$@"; }

# env_line KEY [default] — literal read from .env (no shell expansion, so
# $$ / $ values elsewhere in the file can't interfere).
env_line() {
  local v
  v="$(awk -v k="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    substr(line, 1, length(k) + 1) == k "=" { print substr(line, length(k) + 2); exit }
  ' "$ENV_FILE" 2>/dev/null)" || v=""
  [ -n "$v" ] || v="${2:-}"
  printf '%s' "$v"
}

if [ -f "$ENV_FILE" ]; then
  NET="$(env_line PROXY_NETWORK proxy)"
  SUBNET="$(env_line PROXY_SUBNET)"
else
  NET="proxy"
  SUBNET="172.18.0.0/24"
fi
[ -n "$NET" ] || NET="proxy"

if docker network inspect "$NET" >/dev/null 2>&1; then
  out ok "network '$NET' already exists — reusing it (TRAEFIK_IP must fall inside its subnet)"
  exit 0
fi

if [ -n "$SUBNET" ]; then
  if ! docker network create --subnet "$SUBNET" "$NET" >/dev/null 2>&1; then
    {
      out fail "could not create network '$NET' with subnet $SUBNET — most likely it collides with another Docker network on this host."
      out fail "Fix: pick a free range in .env (PROXY_SUBNET, keep TRAEFIK_IP inside it) or reuse an existing one via PROXY_NETWORK."
      echo "   Networks on this host:"
      docker network ls --format '     {{.Name}}  ({{.Driver}})' 2>/dev/null | grep -v -E '^ *(bridge|host|none)$'
    } >&2 || true
    exit 1
  fi
  out ok "created network '$NET' with subnet $SUBNET"
else
  if ! docker network create "$NET" >/dev/null 2>&1; then
    {
      out fail "could not create network '$NET'."
      echo "   Networks on this host:"
      docker network ls --format '     {{.Name}}  ({{.Driver}})' 2>/dev/null | grep -v -E '^ *(bridge|host|none)$'
    } >&2 || true
    exit 1
  fi
  out ok "created network '$NET' (default Docker subnet; align TRAEFIK_IP accordingly)"
fi
