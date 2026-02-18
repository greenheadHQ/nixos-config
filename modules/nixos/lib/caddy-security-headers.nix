# modules/nixos/lib/caddy-security-headers.nix
# Caddy virtualHost 공통 보안 헤더 (caddy.nix + dev-proxy에서 공유)
#
# Tailscale 내부 전용 환경(100.79.80.95:443)에서는 실질적 보안 효과가 제한적이다.
# 외부 노출이 없으므로 HSTS, X-Frame-Options 등이 방어하는 공격 벡터가 사실상 부재하나,
# 외부 노출 전환 시 이 헤더들이 필수이므로 삭제하지 않고 유지한다.
''
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains" # 외부 전환 시 유지 필수
    X-Content-Type-Options "nosniff"                                # 외부 전환 시 유지 필수
    X-Frame-Options "SAMEORIGIN"                                    # 외부 전환 시 유지 필수
    Referrer-Policy "strict-origin-when-cross-origin"               # 외부 전환 시 유지 필수
    -X-Powered-By
    -Server
  }
''
