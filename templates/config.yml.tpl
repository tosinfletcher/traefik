---
# File-provider configuration (middlewares + WireGuard router) — rendered from
# this template by `just render`. Do not hand-edit config/config.yml; edit this
# template and re-render instead.

http:
  middlewares:
    default-security-headers:
      headers:
        contentTypeNosniff: true # X-Content-Type-Options=nosniff
        forceSTSHeader: true # emit Strict-Transport-Security even on HTTP requests
        frameDeny: false
        referrerPolicy: "strict-origin-when-cross-origin"
        stsIncludeSubdomains: true # includeSubdomains on the HSTS header
        stsPreload: true # preload flag on the HSTS header
        stsSeconds: 31536000 # max-age: 1 year
        contentSecurityPolicy: "default-src 'self'"
        customRequestHeaders:
          X-Forwarded-Proto: https
    https-redirectscheme:
      redirectScheme:
        scheme: https
        permanent: true
    middlewares-authentik:
      forwardAuth:
        address: $AUTHENTIK_URL
        trustForwardHeader: true
        authResponseHeaders:
          - X-authentik-username
          - X-authentik-groups
          - X-authentik-entitlements
          - X-authentik-email
          - X-authentik-name
          - X-authentik-uid
          - X-authentik-jwt
          - X-authentik-meta-jwks
          - X-authentik-meta-outpost
          - X-authentik-meta-provider
          - X-authentik-meta-app
          - X-authentik-meta-version
    # The dashboard router + its basicAuth/sslheader middlewares are defined
    # in docker-compose.yml (labels section, user-owned — no script ever
    # writes to that file). This template must NOT re-define them.

  routers:
    wireguard:
      rule: 'Host(`$WIREGUARD_DOMAIN`)'
      entryPoints:
        - https
      service: wireguard
      tls:
        certResolver: cloudflare

  services:
    wireguard:
      loadBalancer:
        servers:
          - url: $WIREGUARD_BACKEND_URL
