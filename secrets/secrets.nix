# agenix CLI가 사용하는 파일
# 새 secret 추가: nix run github:ryantm/agenix -- -e new-secret.age
# 재암호화: nix run github:ryantm/agenix -- -r
#
# 참고: agenix는 SSH 공개키 형식으로 암호화하면 SSH 비밀키로 복호화 가능
# age 공개키(age1...) 형식은 age 비밀키(AGE-SECRET-KEY-...)가 필요
let
  # SSH 공개키는 constants.nix에서 단일 소스로 관리
  constants = import ../libraries/constants.nix;

  allHosts = [
    constants.sshKeys.macbook
    constants.sshKeys.minipc
  ];

  # MiniPC(NixOS)에서만 필요한 서버 전용 시크릿
  minipcOnly = [ constants.sshKeys.minipc ];
in
{
  # 서비스별 Pushover credentials (독립적 토큰 revocation + API rate limit 분리)
  "pushover-claude-code.age".publicKeys = allHosts;
  "pushover-atuin.age".publicKeys = allHosts;
  "pushover-fail2ban.age".publicKeys = minipcOnly;

  "pane-note-links.age".publicKeys = allHosts;

  # Immich PostgreSQL 비밀번호
  "immich-db-password.age".publicKeys = minipcOnly;

  # Immich CLI 업로드 (FolderAction)
  "immich-api-key.age".publicKeys = allHosts;
  "pushover-immich.age".publicKeys = allHosts;

  # Anki Sync Server 비밀번호
  "anki-sync-password.age".publicKeys = minipcOnly;

  # Copyparty 파일 서버 비밀번호
  "copyparty-password.age".publicKeys = minipcOnly;

  # Vaultwarden 관리자 패널 토큰
  "vaultwarden-admin-token.age".publicKeys = minipcOnly;

  # Caddy HTTPS 인증서 발급용 Cloudflare DNS API 토큰
  "cloudflare-dns-api-token.age".publicKeys = minipcOnly;

  # 서비스 업데이트 알림용 Pushover credentials
  "pushover-uptime-kuma.age".publicKeys = minipcOnly;
  "pushover-copyparty.age".publicKeys = minipcOnly;
}
