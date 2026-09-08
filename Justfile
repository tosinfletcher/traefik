# ─────────────────────────────────────────────────────────────────────
#  Traefik reverse proxy — task runner (just)
#
#    just            # command reference
#    just bootstrap  # one-time setup: .env, shared proxy network, cf-token
#    just up         # validate .env → render config/ → docker compose up -d
#    just ps/logs    # container status · follow the logs
#    just down/restart · just cred <user> <pass> · just clean
#
#  Requirements: bash, docker (+compose v2), envsubst (gettext), `just`,
#  htpasswd (apache2-utils / httpd-tools — for `just cred`).
#
#  NOTE: Just (this version) runs every recipe line in its OWN shell and does
#  not retain state between lines, AND it forbids a multi-line recipe body from
#  exceeding the first line's indent. Stateful flows are therefore each ONE
#  `bash -c` line that owns its error handling and closes on a colored verdict:
#
#        ✓ green  done    → success            (stdout)
#        ⚠ yellow warned  → finished w/ warn   (stdout)
#        ✗ red    bad     → failure + hint     (stdout)
#
#  bin/out.sh drops color automatically when piped / NO_COLOR is set, so
#  `just … | tee log` stays clean while a terminal shows the full styling.
# ─────────────────────────────────────────────────────────────────────

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias b := bootstrap
alias r := render

# ── reference ───────────────────────────────────────────────────────────────
default:
    @bin/out.sh title "traefik · reverse-proxy task runner"
    @bin/out.sh hr
    @bin/out.sh group "setup"
    @bin/out.sh cmd "just bootstrap|one-time: .env, proxy network, cf-token"
    @bin/out.sh cmd "just cred U P |write the dashboard Basic-Auth (bcrypt) into .env"
    @bin/out.sh group "run"
    @bin/out.sh cmd "just up|validate .env → render config/ → docker compose up -d"
    @bin/out.sh cmd "just down|stop & remove the stack   (network + volume survive)"
    @bin/out.sh cmd "just restart|bounce the running traefik container"
    @bin/out.sh group "inspect"
    @bin/out.sh cmd "just ps|container status   (green / red verdict)"
    @bin/out.sh cmd "just logs|follow live logs         (Ctrl-C to stop)"
    @bin/out.sh cmd "just doctor|full validation   (pass / warn / fail summary)"
    @bin/out.sh group "config"
    @bin/out.sh cmd "just render|render templates/ → config/"
    @bin/out.sh cmd "just config|print the fully-interpolated compose model"
    @bin/out.sh group "cleanup"
    @bin/out.sh cmd "just clean|delete the rendered config/ files"
    @bin/out.sh hr
    @bin/out.sh note "color auto-disables when piped / NO_COLOR set — see README.md for .env reference"

# ── setup: one-time bootstrap ───────────────────────────────────────────────
bootstrap:
    @bash -c 'set -uo pipefail; soft=0; bin/out.sh title "bootstrap · one-time setup"; bin/out.sh hr; if [ ! -f .env ]; then cp .env.example .env && bin/out.sh ok ".env created from template — edit it now (domain, emails, WireGuard host, dashboard auth)"; else bin/out.sh ok ".env already present"; fi; if ! bin/ensure-network.sh; then soft=1; fi; if [ -f cf-token ]; then chmod 600 cf-token 2>/dev/null; bin/out.sh ok "cf-token present (Cloudflare DNS-scope)"; else soft=1; bin/out.sh warn "cf-token MISSING — save a Cloudflare DNS token into ./cf-token"; bin/out.sh hint "printf %s <your-dns-token> > cf-token && chmod 600 cf-token"; fi; if ! command -v envsubst >/dev/null 2>&1; then soft=1; bin/out.sh warn "envsubst not found — install gettext (apt-get install gettext / brew install gettext)"; fi; if [ "$soft" -eq 1 ]; then bin/out.sh warned "bootstrap finished with the warnings above — then run: just up"; else bin/out.sh done "bootstrap OK — next: finish .env, then run just up"; fi'

# ── run: validate → render → start ──────────────────────────────────────────
up:
    @bash -c 'set -uo pipefail; bin/out.sh title "up · validate → render → start"; bin/out.sh hr; if ! DERIVED="$(bin/derive.sh)"; then bin/out.sh bad ".env invalid or missing — fix it, or run: just bootstrap"; exit 1; fi; eval "$DERIVED"; if ! bin/ensure-network.sh; then bin/out.sh bad "proxy network not ready (see above) — fix PROXY_SUBNET in .env and retry"; exit 1; fi; mkdir -p config 2>/dev/null; if ! envsubst < templates/traefik.yml.tpl > config/traefik.yml 2>/dev/null; then bin/out.sh bad "render FAILED — check templates/traefik.yml.tpl and your .env"; exit 1; fi; if ! envsubst < templates/config.yml.tpl > config/config.yml 2>/dev/null; then bin/out.sh bad "render FAILED — check templates/config.yml.tpl and your .env"; exit 1; fi; bin/out.sh ok "rendered   config/traefik.yml  +  config/config.yml"; if docker compose up -d --remove-orphans >/dev/null 2>&1; then bin/out.sh ok "compose stack started"; bin/out.sh done "Traefik is LIVE → https://${DASHBOARD_SUBDOMAIN:-traefik}.${DOMAIN}     (status: just ps)"; else bin/out.sh err "docker compose up FAILED"; bin/out.sh hint "why: just logs · state: just ps · full check: just doctor"; bin/out.sh bad "up FAILED — Traefik did not start"; exit 1; fi'

# ── run: teardown / restart ─────────────────────────────────────────────────
down:
    @bash -c 'set -uo pipefail; bin/out.sh title "down · stop & remove the stack"; bin/out.sh hr; if docker compose down >/dev/null 2>&1; then bin/out.sh ok "traefik stack stopped & removed"; bin/out.sh done "DOWN — shared network + ACME volume survive     (revive: just up)"; else bin/out.sh err "docker compose down FAILED"; bin/out.sh hint "daemon: docker info · running: just ps · forced: docker compose down --remove-orphans"; bin/out.sh bad "down FAILED — could not stop the stack"; exit 1; fi'

restart:
    @bash -c 'set -uo pipefail; bin/out.sh title "restart · bounce traefik"; bin/out.sh hr; eval "$(bin/derive.sh 2>/dev/null)" 2>/dev/null || true; DOMAIN="${DOMAIN:-}"; DASHBOARD_SUBDOMAIN="${DASHBOARD_SUBDOMAIN:-traefik}"; if docker compose restart traefik >/dev/null 2>&1; then bin/out.sh ok "traefik container restarted"; bin/out.sh done "RESTART OK → https://${DASHBOARD_SUBDOMAIN:-traefik}.${DOMAIN}"; else bin/out.sh err "docker compose restart FAILED (container likely not running)"; bin/out.sh hint "start first: just up · state: just ps · why: just logs"; bin/out.sh bad "RESTART FAILED"; exit 1; fi'

# ── inspect ─────────────────────────────────────────────────────────────────
ps:
    @bash -c 'set -uo pipefail; bin/out.sh title "traefik · status"; bin/out.sh hr; eval "$(bin/derive.sh 2>/dev/null)" 2>/dev/null || true; DOMAIN="${DOMAIN:-}"; DASHBOARD_SUBDOMAIN="${DASHBOARD_SUBDOMAIN:-traefik}"; out="$(docker compose ps 2>&1)" || out=""; [ -n "$out" ] && printf "%s\n" "$out"; if printf "%s" "$out" | grep -Eiq "up [0-9]"; then bin/out.sh done "RUNNING — dashboard: https://${DASHBOARD_SUBDOMAIN:-traefik}.${DOMAIN}"; elif printf "%s" "$out" | grep -Eiq "no running|exited|unhealthy|not found|no such"; then bin/out.sh bad "NOT RUNNING — start it: just up     ·  why: just logs"; else bin/out.sh warned "status above — inspect: just logs · just doctor"; fi; exit 0'

logs:
    @bin/out.sh title "traefik · live logs"
    @bin/out.sh hr
    @bin/out.sh sub "following the traefik stream — Ctrl-C to stop"
    @exec docker compose logs -f --tail 100 traefik

doctor:
    @bash -c 'set -uo pipefail; bin/out.sh title "doctor · full validation"; bin/out.sh hr; n_ok=0; n_warn=0; n_fail=0; rec() { bin/out.sh "$1" "$2 — $3"; case "$1" in ok) n_ok=$((n_ok+1));; warn) n_warn=$((n_warn+1));; fail) n_fail=$((n_fail+1));; esac; }; if DERIVED="$(bin/derive.sh)"; then eval "$DERIVED" 2>/dev/null || true; if [ -n "${DASHBOARD_SUBDOMAIN:-}" ] && [ -n "${DOMAIN:-}" ]; then rec ok "environment" "dashboard ${DASHBOARD_SUBDOMAIN}.${DOMAIN} · wireguard ${WIREGUARD_DOMAIN} → ${WIREGUARD_BACKEND_URL}"; else rec fail "environment" "DASHBOARD_SUBDOMAIN / DOMAIN unset (dashboard label degrades)"; fi; else rec fail "environment" ".env invalid or missing (details above)"; fi; if [ -f cf-token ]; then rec ok "secret" "cf-token present"; else rec fail "secret" "cf-token MISSING (run: just bootstrap)"; fi; if docker compose config --quiet 2>/dev/null; then rec ok "compose" "docker-compose.yml resolves"; else rec fail "compose" "compose file does not resolve (inspect: just config)"; fi; if [ -s config/traefik.yml ] && [ -s config/config.yml ]; then rec ok "renders" "config/traefik.yml + config/config.yml present"; else rec fail "renders" "missing (run: just render)"; fi; if docker info >/dev/null 2>&1; then rec ok "docker" "daemon reachable"; else rec warn "docker" "daemon NOT reachable on this host"; fi; if docker network inspect "${PROXY_NETWORK:-proxy}" >/dev/null 2>&1; then rec ok "network" "${PROXY_NETWORK:-proxy} present"; elif bin/ensure-network.sh >/dev/null 2>&1; then rec ok "network" "${PROXY_NETWORK:-proxy} (created just now)"; else rec fail "network" "${PROXY_NETWORK:-proxy} missing (run: bin/ensure-network.sh)"; fi; total=$((n_ok + n_warn + n_fail)); bin/out.sh step "summary — ${n_ok} passed · ${n_warn} warning(s) · ${n_fail} failed     (${total} checks)"; if [ "$n_fail" -gt 0 ]; then bin/out.sh bad "doctor found ${n_fail} failure(s) — the red lines above need attention"; exit 1; elif [ "$n_warn" -gt 0 ]; then bin/out.sh warned "doctor — ${n_warn} warning(s) above, no hard failures"; else bin/out.sh done "doctor — all ${total} checks passed"; fi'

# ── config: inspect / render ────────────────────────────────────────────────
config:
    @bash -c 'set -uo pipefail; bin/out.sh title "resolved compose model · docker-compose.yml + .env"; bin/out.sh hr; bin/derive.sh >/dev/null 2>&1 || bin/out.sh warn ".env raised validation notes above — composing from it anyway"; if docker compose config; then bin/out.sh done "compose model resolves"; else bin/out.sh bad "compose model does NOT resolve — check .env and docker-compose.yml"; exit 1; fi'

render:
    @bash -c 'set -uo pipefail; bin/out.sh title "render · templates/ → config/"; bin/out.sh hr; if ! command -v envsubst >/dev/null 2>&1; then bin/out.sh err "envsubst not found"; bin/out.sh hint "install gettext (apt-get install gettext / brew install gettext)"; bin/out.sh bad "render ABORTED — envsubst missing"; exit 1; fi; if ! DERIVED="$(bin/derive.sh)"; then bin/out.sh bad ".env invalid or missing (see above) — fix .env, or run: just bootstrap"; exit 1; fi; eval "$DERIVED"; mkdir -p config 2>/dev/null; if envsubst < templates/traefik.yml.tpl > config/traefik.yml && envsubst < templates/config.yml.tpl > config/config.yml; then bin/out.sh ok "config/traefik.yml    ACME: ${ACME_EMAIL} @ ${ACME_CASERVER}"; bin/out.sh ok "config/config.yml     wireguard: ${WIREGUARD_DOMAIN} → ${WIREGUARD_BACKEND_URL}"; bin/out.sh done "rendered — dashboard label → ${DASHBOARD_SUBDOMAIN:-traefik}.${DOMAIN}"; else bin/out.sh bad "render FAILED — templates/ × .env derivation"; exit 1; fi'

# ── setup helper: dashboard Basic-Auth ──────────────────────────────────────
cred USERNAME PASSWORD:
    @bash -c 'set -uo pipefail; u="{{USERNAME}}"; p="{{PASSWORD}}"; bin/out.sh title "cred · dashboard Basic-Auth"; bin/out.sh hr; if ! command -v htpasswd >/dev/null 2>&1; then bin/out.sh err "htpasswd not found"; bin/out.sh hint "Debian/Ubuntu: apt-get install apache2-utils  ·  macOS: brew install httpd-tools"; bin/out.sh bad "cred ABORTED — htpasswd is required to generate the hash"; exit 1; fi; if [ -z "$u" ] || [ -z "$p" ]; then bin/out.sh bad "usage: just cred <username> <password>"; exit 2; fi; raw="$(htpasswd -nbBC 10 "$u" "$p")" || { bin/out.sh bad "htpasswd failed for user $u"; exit 1; }; doubled="${raw//\$/\$\$}"; line="TRAEFIK_DASHBOARD_CREDENTIALS=$doubled"; if [ -f .env ] && grep -q "^TRAEFIK_DASHBOARD_CREDENTIALS=" .env 2>/dev/null; then tmp="$(mktemp)"; grep -v "^TRAEFIK_DASHBOARD_CREDENTIALS=" .env > "$tmp" && mv "$tmp" .env; else if [ ! -f .env ]; then cp .env.example .env 2>/dev/null || { bin/out.sh bad "no .env or .env.example to upsert into"; exit 1; }; fi; fi; printf "%s\n" "$line" >> .env; bin/out.sh ok "Basic-Auth for user ${u} written to .env   (doubled-dollar form, compose-ready)"; bin/out.sh done "CREDS SAVED — apply with: just up"'

# ── cleanup ─────────────────────────────────────────────────────────────────
clean:
    @bash -c 'set -uo pipefail; bin/out.sh title "clean · remove rendered config/"; bin/out.sh hr; if rm -f config/traefik.yml config/config.yml 2>/dev/null; then bin/out.sh ok "removed config/traefik.yml  +  config/config.yml"; bin/out.sh done "DONE — recreate with: just render"; else bin/out.sh bad "could not delete the rendered config files"; exit 1; fi'
