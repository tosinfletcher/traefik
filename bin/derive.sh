#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# derive.sh — normalize .env into a validated, canonical variable set.
#
# Contract:
#   - Reads $ROOT/.env (or $ENV_FILE) and validates it.
#   - Applies defaults and derives composite values (domains, backend URLs).
#   - Prints a series of `export KEY=VALUE` statements on stdout — safe to
#     `eval`. Human-readable notes/warnings go to stderr.
#   - Exits non-zero with an actionable message on any invalid configuration.
#
# Used by: Justfile (render / up / doctor) and directly, e.g.:
#     eval "$(bin/derive.sh)" && envsubst < templates/traefik.yml.tpl > config/traefik.yml
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/out.sh"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

# Note: derive.sh's STDOUT is captured as the export bundle — status messages
# must stay on stderr (out.sh fail/warn do exactly that).
note() { "$OUT" warn "$@"; }
fail() { "$OUT" fail "$@"; exit 1; }

[ -f "$ENV_FILE" ] || fail ".env not found (looked in $ENV_FILE). Run: cp .env.example .env and fill it in."

# ---- read .env literally — deliberately NOT shell-sourced ------------------
# Compose (v2+) runs .env VALUES through variable interpolation: a raw `$X` is
# consumed as a variable reference, and `$$` is the documented escape for a
# literal `$`. Bcrypt hashes contain `$`, so they are stored doubled in .env
# (user:$$2y$$05$$hash) and consumed by Compose as user:$2y$05$hash — correct.
# Sourcing this file in bash would corrupt BOTH forms (`$2` → positional,
# `$$` → PID), so values are extracted literally with sed instead.
env_get() { # env_get KEY — prints the (unescaped) raw value, or nothing
  local raw
  raw="$(awk -v k="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    substr(line, 1, length(k) + 1) == k "=" { print substr(line, length(k) + 2); exit }
  ' "$ENV_FILE")"
  # strip one pair of matching surrounding quotes, if present
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  # unescape the compose contract: $$ → $
  printf '%s' "${raw//'$$'/'$'}"
}

TRAEFIK_IMAGE="$(env_get TRAEFIK_IMAGE)"
TRAEFIK_TAG="$(env_get TRAEFIK_TAG)"
DOMAIN="$(env_get DOMAIN)"
DASHBOARD_SUBDOMAIN="$(env_get DASHBOARD_SUBDOMAIN)"
WIREGUARD_SUBDOMAIN="$(env_get WIREGUARD_SUBDOMAIN)"
WIREGUARD_DOMAIN="$(env_get WIREGUARD_DOMAIN)"
CF_API_EMAIL="$(env_get CF_API_EMAIL)"
ACME_EMAIL="$(env_get ACME_EMAIL)"
ACME_STAGING="$(env_get ACME_STAGING)"
PROXY_NETWORK="$(env_get PROXY_NETWORK)"
PROXY_SUBNET="$(env_get PROXY_SUBNET)"
TRAEFIK_IP="$(env_get TRAEFIK_IP)"
ENTRYPOINT_HTTPS_PORT="$(env_get ENTRYPOINT_HTTPS_PORT)"
WIREGUARD_HOST="$(env_get WIREGUARD_HOST)"
WIREGUARD_PORT="$(env_get WIREGUARD_PORT)"
WIREGUARD_SCHEME="$(env_get WIREGUARD_SCHEME)"
AUTHENTIK_HOST="$(env_get AUTHENTIK_HOST)"
AUTHENTIK_PORT="$(env_get AUTHENTIK_PORT)"
TRAEFIK_API_DEBUG="$(env_get TRAEFIK_API_DEBUG)"
TRAEFIK_DASHBOARD_CREDENTIALS="$(env_get TRAEFIK_DASHBOARD_CREDENTIALS)"

# env_raw KEY — literal line value (quotes stripped) WITHOUT the $$ → $ unescape.
env_raw() {
  local raw
  raw="$(awk -v k="$1" '
    { line = $0; sub(/^[ \t]+/, "", line) }
    substr(line, 1, length(k) + 1) == k "=" { print substr(line, length(k) + 2); exit }
  ' "$ENV_FILE")"
  case "$raw" in
    \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    \'*\') raw="${raw#\'}"; raw="${raw%\'}" ;;
  esac
  printf '%s' "$raw"
}

# ---- defaults ----------------------------------------------------------------
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik}"
DASHBOARD_SUBDOMAIN="${DASHBOARD_SUBDOMAIN:-traefik}"
WIREGUARD_SUBDOMAIN="${WIREGUARD_SUBDOMAIN:-wireguard}"
ACME_STAGING="${ACME_STAGING:-false}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
PROXY_SUBNET="${PROXY_SUBNET:-172.18.0.0/24}"
TRAEFIK_IP="${TRAEFIK_IP:-172.18.0.254}"
ENTRYPOINT_HTTPS_PORT="${ENTRYPOINT_HTTPS_PORT:-443}"
WIREGUARD_PORT="${WIREGUARD_PORT:-51821}"
WIREGUARD_SCHEME="${WIREGUARD_SCHEME:-http}"
AUTHENTIK_HOST="${AUTHENTIK_HOST:-authentik}"
AUTHENTIK_PORT="${AUTHENTIK_PORT:-9000}"
TRAEFIK_API_DEBUG="${TRAEFIK_API_DEBUG:-false}"

# ---- required values -------------------------------------------------------
[ -n "${CF_API_EMAIL:-}" ] || fail "CF_API_EMAIL is required in .env (Cloudflare account email / ACME contact)."
[ -n "${WIREGUARD_HOST:-}" ] || fail "WIREGUARD_HOST is required in .env (internal address of your WireGuard management endpoint, e.g. 192.168.0.10)."
[ -n "${TRAEFIK_DASHBOARD_CREDENTIALS:-}" ] || fail "TRAEFIK_DASHBOARD_CREDENTIALS is required in .env (format: 'user:\$2y\$<bcrypt-hash>'). Generate with: htpasswd -nbBC 10 <user> <pass>"
# Any '$' left after removing well-formed '$$' pairs means a single (non-doubled)
# dollar sign, which compose would corrupt via variable interpolation.
RAW_CRED="$(env_raw TRAEFIK_DASHBOARD_CREDENTIALS)"
case "${RAW_CRED//'$$'/}" in
  *'$'*) fail "TRAEFIK_DASHBOARD_CREDENTIALS contains a single (non-doubled) dollar sign. In .env every \$ must be DOUBLED — user:\$\$2y\$\$05\$\$hash — because compose interpolates .env values." ;;
esac
case "$TRAEFIK_DASHBOARD_CREDENTIALS" in
  *'$2y$'*|*'$2b$'*) : ;;
  *) fail "TRAEFIK_DASHBOARD_CREDENTIALS is not a bcrypt hash (must match user:\$2y\$...). Generative note: in .env, DOUBLE every dollar sign in the value (user:\$\$2y\$\$05\$\$hash) — compose interpolates .env values. Generate the hash with: htpasswd -nbBC 10 <user> <pass>" ;;
esac

# ---- warning: dashboard label inputs (consumed by Compose, not by us) ------
# The compose label composes Host(`${DASHBOARD_SUBDOMAIN}.${DOMAIN}`); if either
# is missing, the dashboard host silently degrades — loud about it.
if [ -z "${DASHBOARD_SUBDOMAIN}" ] || [ -z "${DOMAIN}" ]; then
  note "WARNING: DASHBOARD_SUBDOMAIN/DOMAIN must be set for the dashboard label (Host(\`${DASHBOARD_SUBDOMAIN?}.\${DOMAIN?}\`))."
fi

# ---- domain derivation -----------------------------------------------------
# The DASHBOARD host is owned by the Compose labels (user file): they compose
# `${DASHBOARD_SUBDOMAIN}.${DOMAIN}` directly, so derive.sh only surfaces the
# raw .env values for display and does NOT fabricate a composite.
# WIREGUARD_DOMAIN is consumed by templates/config.yml.tpl, so a default
# derivation applies there.
if [ -n "${WIREGUARD_DOMAIN:-}" ]; then
  :
else
  [ -n "${DOMAIN:-}" ] || fail "Set DOMAIN in .env (your zone, e.g. example.com), or set WIREGUARD_DOMAIN explicitly."
  WIREGUARD_DOMAIN="${WIREGUARD_SUBDOMAIN:-wireguard}.${DOMAIN}"
  note "derived WIREGUARD_DOMAIN=$WIREGUARD_DOMAIN"
fi

# ---- ACME ------------------------------------------------------------------
ACME_EMAIL="${ACME_EMAIL:-$CF_API_EMAIL}"
case "${ACME_STAGING:-false}" in
  true | True | TRUE | 1)
    ACME_CASERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
    note "ACME_STAGING enabled — certificates from the Let's Encrypt STAGING CA (NOT valid for production traffic)"
    ;;
  *) ACME_CASERVER="https://acme-v02.api.letsencrypt.org/directory" ;;
esac

# ---- backends --------------------------------------------------------------
WIREGUARD_SCHEME="${WIREGUARD_SCHEME:-http}"
case "$WIREGUARD_SCHEME" in
  http | https) : ;;
  *) fail "WIREGUARD_SCHEME must be http or https (got: $WIREGUARD_SCHEME)" ;;
esac
WIREGUARD_BACKEND_URL="${WIREGUARD_SCHEME}://${WIREGUARD_HOST}:${WIREGUARD_PORT:-51821}"
AUTHENTIK_URL="http://${AUTHENTIK_HOST:-authentik}:${AUTHENTIK_PORT:-9000}/outpost.goauthentik.io/auth/traefik"
TRAEFIK_API_DEBUG="${TRAEFIK_API_DEBUG:-false}"
case "$TRAEFIK_API_DEBUG" in
  true | false) : ;;
  *) fail "TRAEFIK_API_DEBUG must be 'true' or 'false' (got: $TRAEFIK_API_DEBUG)" ;;
esac

# ---- sanity: no stray values ----------------------------------------------
# Cloudflare DNS tokens must never sit in .env; they belong in ./cf-token.
if [ -n "$(env_get CF_DNS_API_TOKEN)" ] || [ -n "$(env_get CLOUDFLARE_API_TOKEN)" ]; then
  note "WARNING: a Cloudflare API token is present in .env — remove it and store it in ./cf-token instead (Docker secret)."
fi

# ---- emit -------------------------------------------------------------------
# The bundle covers exactly what the templates consume plus what the Justfile
# displays. TRAEFIK_DASHBOARD_CREDENTIALS is validated above but NOT emitted:
# it is consumed directly by Compose from .env (label interpolation).
# `printf '%q'` quotes values so the output stays eval-safe even if a value
# contains spaces or shell metacharacters.
emit() { printf 'export %s=%q\n' "$1" "${!1}"; }
emit CF_API_EMAIL
emit ACME_EMAIL
emit ACME_CASERVER
emit DOMAIN
emit DASHBOARD_SUBDOMAIN
emit WIREGUARD_DOMAIN
emit WIREGUARD_BACKEND_URL
emit AUTHENTIK_URL
emit TRAEFIK_API_DEBUG
emit PROXY_NETWORK
emit PROXY_SUBNET
emit TRAEFIK_IP
emit ENTRYPOINT_HTTPS_PORT
