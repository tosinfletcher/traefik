---
# Traefik static (core) configuration — rendered from this template by `just render`.
# Variables are filled in by bin/derive.sh from your .env. Do not hand-edit the
# rendered output (config/traefik.yml); edit this template and re-render instead.

api:
  dashboard: true
  debug: $TRAEFIK_API_DEBUG

entryPoints:
  https:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false # containers must opt in with traefik.enable=true
  file:
    filename: /config.yml
    watch: true # live-reload config/config.yml changes without a restart

certificatesResolvers:
  cloudflare:
    acme:
      caServer: $ACME_CASERVER
      email: $ACME_EMAIL
      storage: /etc/traefik/acme/acme.json
      dnsChallenge:
        provider: cloudflare # token is read from the cf-token Docker secret (CF_DNS_API_TOKEN_FILE)
        #disablePropagationCheck: true # uncomment if DNS propagation checks misbehave for your zone
        resolvers:
          - "1.1.1.1:53"
          - "1.0.0.1:53"

# Optional file logging. Enable by uncommenting and mounting a ./logs volume in
# docker-compose.yml as well (./logs:/var/log/traefik):
# log:
#   level: "INFO"
#   filePath: "/var/log/traefik/traefik.log"
# accessLog:
#   filePath: "/var/log/traefik/access.log"
