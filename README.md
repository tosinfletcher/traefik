# traefik

A **fully dynamic, env-driven Traefik** reverse-proxy deployment. One codebase, any host: every domain, backend address, network, port, image tag and credential is supplied through `.env` (+ one secret file), validated, and rendered into the Traefik config at deploy time — no hardcoded values anywhere.

It terminates TLS for every service on the box, obtains and renews Let's Encrypt certificates **automatically via Cloudflare DNS-01 challenge** (port 80 never needed), serves an authenticated dashboard, forwards your `wireguard.<domain>` host to your internal WireGuard management endpoint, and ships reusable security middlewares plus an optional authentik forward-auth hook.

---

## Table of Contents

- [How it works](#how-it-works)
- [Repository structure](#repository-structure)
- [Quick start](#quick-start)
- [Configuration reference (`.env`)](#configuration-reference-env)
- [Dashboard credentials (`just cred`)](#dashboard-credentials-just-cred)
- [The render pipeline](#the-render-pipeline)
- [Design decisions & platform gotchas](#design-decisions--platform-gotchas)
- [Exposing your own services](#exposing-your-own-services)
- [Operations & troubleshooting](#operations--troubleshooting)
- [Security hardening](#security-hardening)

---

## How it works

```
 .env + cf-token                        just up (or any render/up path)
 ┌────────────────┐           ┌────────────────────────────────────────────┐
 │ DOMAIN         │           │  bin/derive.sh                             │
 │ CF_API_EMAIL   │──────────►│   · validates every value (actionable      │
 │ WIREGUARD_HOST │           │     errors, rejects plaintext / single-$)  │
 │ TRAEFIK_...    │           │   · derives the WG domain                  │
 └────────────────┘           │   · unescapes compose's $$ -> $   (see it)  │
                              │   · emits the variable bundle for render   │
 docker-compose.yml           └───────────────┬────────────────────────────┘
 ┌────────────────┐                           ▼
 │ image / ports  │          ┌────────────────────────────────────────────┐
 │ network + IP   │─────────►│  envsubst × templates/*.yml.tpl            │
 │ volume name    │          │   → config/traefik.yml   (ACME, entrypoint)│
 │ dashboard      │          │   → config/config.yml  (wg router, middle-)│
 │   LABELS (you) │          └───────────────┬────────────────────────────┘
 └────────────────┘                           ▼
      docker compose up ──────────►  traefik container (read-only mounts)
                                     │ ACME DNS-01 ──► Cloudflare API
                                     │   (token via Docker secret cf-token)
                                     ▼
 dashboard ◄── https://${DASHBOARD_SUBDOMAIN}.${DOMAIN} (basic auth; compose label)
 wireguard ◄── https://<WIREGUARD_DOMAIN> → $WIREGUARD_HOST:$WIREGUARD_PORT
```

**Ownership rule:** `docker-compose.yml` — including its labels section — is *user-owned*: no script writes to it or rewrites it. The scripts only (a) read `.env`, (b) render `config/traefik.yml` + `config/config.yml` from the templates, and (c) provision the shared `proxy` network. Every dynamic value flows one way: **your `.env` → everything** (Compose interpolates its own labels directly from `.env`; the render step feeds the templates).
Two providers feed Traefik:

- **File provider** — the rendered `config/traefik.yml` + `config/config.yml` hold everything that must be *exact*: the ACME resolver, the entrypoint, the WireGuard router, and the reusable middlewares. (The dashboard router + its basicAuth/sslheader middlewares live in the *user-owned* `docker-compose.yml` labels.)
- **Docker provider** (`exposedByDefault: false`) — discovers *your* services by container labels on the shared `proxy` network; nothing is ever exposed unless a container opts in.

## Repository structure

```
traefik/
├── .env.example        # the single place to configure this service (copy to .env)
├── .gitignore          # .env, cf-token, rendered config — all excluded
├── bin/
│   ├── derive.sh         # validates .env, derives values, emits canonical exports
│   └── ensure-network.sh # idempotently provisions the shared proxy network
├── docker-compose.yml  # process orchestration; every value ${VARIABLE}-driven
├── templates/
│   ├── traefik.yml.tpl # → config/traefik.yml  (ACME, entrypoint, debug flag)
│   └── config.yml.tpl  # → config/config.yml   (wireguard router, middlewares)
├── config/             # RENDERED output (generated; git-ignored)
├── Justfile            # bootstrap · render · up · down · restart · ps · logs · doctor · cred · config · clean
└── README.md
```

## Quick start

Requirements — **all four must be present** on the machine: **`docker`** (with Compose v2), **`bash`**, **`envsubst`** (gettext), and the task runner **`just`**. `just` is a **hard requirement** of this repo — it drives every command below.

**Install `just` if it isn't present:**

```sh
# macOS (Homebrew)
brew install just

# Linux — Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y just
#   other distros:   dnf install just   ·   pacman -S just   ·   nix profile install nixpkgs#just

# Distro-agnostic (any Linux or macOS) — official prebuilt binary:
curl --proto '=https' --tlsv1.2 -sSf \
  https://raw.githubusercontent.com/casey/just/master/install.sh | sh
```

Check it works with `just --version`. (The recipes are plain bash, so if you ever need to step outside `just` they're readable line-by-line — but the intended entry point is always `just`.)

```bash
git clone <this repo> && cd traefik

just bootstrap            # creates .env, idempotently provisions the shared proxy network, checks cf-token
# → edit .env: your DOMAIN, CF_API_EMAIL, WIREGUARD_HOST, …
# → create the token file (raw token, single line):
printf '%s' '<cloudflare-dns-token>' > cf-token && chmod 600 cf-token
#   · token scope: Zone → DNS → Edit
just cred <user> <pass>   # optional: generate the dashboard Basic-Auth bcrypt line

just doctor               # full validation: env, secrets, compose, renders
just up                   # render + start; then hit https://<dashboard-domain>
```

(The `proxy` network is declared `external: true`, so it must exist before `up`; `bin/ensure-network.sh` creates it with your `PROXY_SUBNET` if missing and reuses it otherwise. `docker compose down` never destroys it — deliberate, since other services share it.)

(`bin/derive.sh` also validates `.env` and exports its derived values, so both the `envsubst` step and the `docker compose` step — which reads `.env` for image tag, network, ports etc. — see the same canonical values.)

## Configuration reference (`.env`)

Copy `.env.example` → `.env`. Both `DOMAIN`/substyle and explicit-domains styles work.

| Variable | Default | Purpose |
|---|---|---|
| `TRAEFIK_IMAGE`, `TRAEFIK_TAG` | `traefik`, `v3.7` | Image name and **pinned** tag. |
| `DOMAIN` | — | Your Cloudflare zone (e.g. `example.com`). Required unless you set the explicit hosts below. |
| `DASHBOARD_SUBDOMAIN` | `traefik` | First label piece of the dashboard host — the compose label composes `Host(${DASHBOARDSUBDOMAIN}.${DOMAIN})`. |
| `WIREGUARD_SUBDOMAIN` | `wireguard` | WireGuard host = `<sub>.<DOMAIN>` (rendered into the WG router). |
| `WIREGUARD_DOMAIN` | — | Optional: explicit full host for the WireGuard forward (overrides the derived one). |
| `CF_API_EMAIL` | — | **Required.** Cloudflare account email; doubles as the Let's Encrypt contact. |
| `ACME_EMAIL` | `= CF_API_EMAIL` | Override the ACME contact only. |
| `ACME_STAGING` | `false` | `true` → sign against Let's Encrypt staging (testing; certs are **not** valid). |
| `PROXY_NETWORK` | `proxy` | Shared network for Traefik + all backends. Declared `external: true`; created if missing by `just bootstrap`/`just up` (`bin/ensure-network.sh`). |
| `PROXY_SUBNET` | `172.18.0.0/24` | Subnet used only when the network is being created; ignored for an existing one. |
| `TRAEFIK_IP` | `172.18.0.254` | Traefik's fixed address on that network — must fall inside the network's actual subnet. |
| `ENTRYPOINT_HTTPS_PORT` | `443` | Host port for HTTPS (container always listens on 443). |
| `WIREGUARD_HOST` | — | **Required.** Internal address of your WireGuard mgmt endpoint. |
| `WIREGUARD_PORT`, `WIREGUARD_SCHEME` | `51821`, `http` | Backend port and `http`/`https`. |
| `AUTHENTIK_HOST`, `AUTHENTIK_PORT` | `authentik`, `9000` | Target of the `middlewares-authentik` forward-auth hook. |
| `TRAEFIK_DASHBOARD_CREDENTIALS` | — | Basic-Auth entry for the dashboard (see below). |
| `TRAEFIK_API_DEBUG` | `false` | Enables Traefik's `/debug` endpoints. |
| `CERTS_VOLUME` | `traefik-certs` | Named volume holding ACME state. |

**`cf-token`** (file, git-ignored): the Cloudflare DNS API token, raw, no quotes. Referenced only via a [Docker secret](https://docs.docker.com/compose/spec/#configs-and-secrets) mounted at `/run/secrets/cf-token` and the `CF_DNS_API_TOKEN_FILE` env var — Traefik's documented way to feed ACME DNS tokens. It never enters `.env`, labels, or the container environment.

**Rendering rule of thumb:** `DOMAIN` + subdomains is the recommended style; explicit `*_DOMAIN` values always win. `bin/derive.sh` fails fast with an actionable message on anything missing or malformed.

## Dashboard credentials (`just cred`)

The dashboard uses HTTP Basic Auth with a **bcrypt** string (`user:$2y$<hash>`). Two gotchas are handled for you:

1. **Compose interpolates `.env` values** — a raw `$` in a value is read as a variable reference, so the repo convention is to *double* every `$` (`user:$$2y$$05$$hash`). Compose then un-escapes `$$`→`$` at label-interpolation time, so Traefik gets the real `user:$2y$…`; `bin/derive.sh` just **validates** it — rejecting single-`$` and plaintext pastes early.
2. Generating the hash is a chore — `just cred <username> <password>` runs `htpasswd -nbBC 10`, doubles the dollars, and upserts the line into `.env`. (Needs `apache2-utils`/`httpd-tools`.)

How it reaches Traefik: the dashboard is wired entirely through **compose labels** in `docker-compose.yml` (`traefik.http.middlewares.traefik-auth.basicauth.users=${TRAEFIK_DASHBOARD_CREDENTIALS}`), which Compose interpolates from `.env` (un-escaping `$$`→`$`) and the **Docker provider** consumes. It is deliberately *not* rendered into `config/config.yml` — `templates/config.yml.tpl` explicitly must not re-define the dashboard router/middlewares.

## The render pipeline

- `bin/derive.sh` reads `.env` **literally** (awk-extracted, never shell-sourced — avoiding `$`-expansion corruption), validates everything, derives composite values, and prints `export …` lines.
- `just render` / `just up` `eval` that bundle and run `envsubst` over the two templates → `config/`.
- Compose mounts those rendered files **read-only**. The container itself needs zero secrets at runtime beyond the CF token file.

To extend: add your own variable to `.env.example`, read it in `derive.sh` (one `env_get` line + any validation), reference it as `$VAR` in a template, and (if Compose also needs it) add a `${VAR:-default}` in `docker-compose.yml`. That's the whole contract.

## Design decisions & platform gotchas

Hard-won, verified findings baked into this design:

| Gotcha | Consequence here |
|---|---|
| **Docker Compose v5.x interpolates `.env` values** — every `$NAME` in a value is consumed as a variable reference (and warns + blanks the rest). | Credentials and any `$`-bearing value use the documented `$$` escape; `derive.sh` unescapes and *rejects* single-`$` credential pastes outright. |
| Some **Compose/go-yaml combinations trip** (`found unknown escape character`) on backtick-containing (Host()) rules depending on how the value renders in the model. | The dashboard label block in `docker-compose.yml` is user-owned and verified working as-written; the WireGuard rule lives in plain-YAML template output. If a different Compose version chokes on a label, rewrite that one label single-quoted (e.g. `'…rule=Host(`host.domain`)'`). |
| **Just (this version) executes each recipe line in its own shell** with no retained state, and rejects multi-line indented shell and `name VAR := $(…)` headers. | Every stateful sequence is a single compound `bash -c '… eval "$(bin/derive.sh)" && …'` line; documented in the Justfile header. |
| bcrypt hashes contain `$`, which Compose's `.env` interpolation would consume. | The `.env` stores it doubled (`$$`); Compose unescapes it when interpolating the label — verified at runtime via `docker inspect`. `derive.sh` rejects single-`$` and plaintext pastes early. |

## Exposing your own services

Because `exposedByDefault` is `false`, any container behind Traefik must (1) join the `proxy` network and (2) set `traefik.enable=true` plus router labels:

```yaml
services:
  myapp:
    image: myapp:latest
    networks: [proxy]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.myapp.rule=Host(`myapp.example.com`)"
      - "traefik.http.routers.myapp.entrypoints=https"
      - "traefik.http.routers.myapp.tls=true"
      - "traefik.http.routers.myapp.tls.certresolver=cloudflare"
      - "traefik.http.routers.myapp.middlewares=default-security-headers@file"
      - "traefik.http.services.myapp.loadbalancer.server.port=3000"

networks:
  proxy:
    external: true   # "proxy" = the shared network — must match PROXY_NETWORK in .env (else add a `name:` here)
```

Reusable middlewares from `config/config.yml` (attach with the `@file` suffix):

| Middleware | Purpose |
|---|---|
| `default-security-headers` | HSTS (includeSubdomains, preload, 1y), nosniff, referrer-policy, CSP `default-src 'self'`, forces `X-Forwarded-Proto: https`. |
| `https-redirectscheme` | Permanent redirect to HTTPS (use on an HTTP entrypoint). |
| `middlewares-authentik` | `forwardAuth` to the authentik outpost (`http://$AUTHENTIK_HOST:$AUTHENTIK_PORT/outpost.goauthentik.io/auth/traefik`); injects `X-authentik-*` identity headers downstream. |

## Operations & troubleshooting

**Dashboard** — `https://<DASHBOARD_SUBDOMAIN>.<DOMAIN>` (Basic Auth). Shows routers, services, middlewares, certificates.

**Logs**

```bash
just logs                       # follow the last 100 lines
docker logs -f traefik          # full history
# file logging: uncomment log/accessLog in templates/traefik.yml.tpl
#               and mount ./logs in docker-compose.yml, then just up
```

**Certificates**

- Stored in the `traefik-certs` volume (`/etc/traefik/acme`); renewals happen automatically via the same Cloudflare DNS challenge.
- Backup:

  ```bash
  docker run --rm -v traefik-certs:/data -v "$PWD":/backup alpine \
    tar czf /backup/traefik-certs.tar.gz -C /data .
  ```

- Testing without burning production rate limits: `ACME_STAGING=true` in `.env`, then `just up`.

**Common issues**

| Symptom | Likely cause / fix |
|---|---|
| No cert for a new host | Token lacks *Zone → DNS → Edit*; domain not on Cloudflare; router `certresolver` isn't `cloudflare`. Check `docker logs traefik` for the ACME error. |
| `Unable to obtain ACME certificate … invalidContact` | `CF_API_EMAIL` rejected by Let's Encrypt (e.g. reserved domains). Use a real account email. |
| Dashboard 401/403 loop | `TRAEFIK_DASHBOARD_CREDENTIALS` isn't a valid bcrypt `user:$2y$…` line — regenerate with `just cred`. |
| `network proxy ... declared as external, but was not found` on `up` | The shared network doesn't exist yet. Run `just bootstrap` (or `docker network create --subnet 172.18.0.0/24 proxy`). |
| `requested IP address (...) is not in the subnet pool` on `up` | The existing `PROXY_NETWORK` uses a different subnet than `TRAEFIK_IP`. Align `TRAEFIK_IP` (or drop the `ipv4_address` line, or set `PROXY_SUBNET` and recreate the network). |
| `Pool overlaps with other one on this address space` (creating the network) | Your chosen `PROXY_SUBNET` collides with an existing Docker network on the host. Pick a free subnet (and keep `TRAEFIK_IP` inside it). |
| 502/503 from Traefik to a backend | Backend not on `proxy`, wrong port in its `loadbalancer.server.port`, or missing `traefik.enable=true`. |
| `found unknown escape character` from `docker compose config` | A double-quoted label contains backticks (Host rule). Rewrite it single-quoted (see exposing services). |
| `secret file not found` on start | `cf-token` missing from the repo directory — recreate it (it's git-ignored by design). |

## Security hardening

- `no-new-privileges`; **all** mounts read-only, including the Docker socket.
- Secrets policy: CF token in a Docker secret file; everything else non-secret in `.env` (git-ignored); bcrypt dashboard auth validated by `derive.sh` before deploy (plaintext and single-`$` pastes rejected).
- `exposedByDefault: false` — opt-in exposure only.
- HSTS preload + subdomains, nosniff, referrer-policy, CSP via `default-security-headers`.
- Log rotation capped (`json-file`, 10 MB × 3). `restart: unless-stopped` honors manual stops.
- `api.debug` off by default.

> **Bring it to CI:** the whole pipeline is `bin/derive.sh` + `envsubst` + `docker compose up`. Any CI (Jenkins, GitLab, GitHub Actions) needs only to provision `.env` + `cf-token` from credentials, then run `just bootstrap`, `just doctor`, and `just up` on the target host.

---

*Stack: Traefik v3 · Docker Compose v2+ · Let's Encrypt (ACME DNS-01) · Cloudflare · `just` + bash.*
