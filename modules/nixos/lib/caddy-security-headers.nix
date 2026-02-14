# modules/nixos/lib/caddy-security-headers.nix
# Caddy virtualHost 공통 보안 헤더 (caddy.nix + dev-proxy에서 공유)
''
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "SAMEORIGIN"
    Referrer-Policy "strict-origin-when-cross-origin"
    -X-Powered-By
    -Server
  }
''
