# agenix CLI가 사용하는 파일
# 새 secret 추가: nix run github:ryantm/agenix -- -e new-secret.age
# 재암호화: nix run github:ryantm/agenix -- -r
#   주의: SA token(opnix-service-account-token.age)은 host key 전용(minipcHostOnly) recipient다.
#   host private key가 없는 Mac에서 전체 rekey는 해당 .age 복호화에 실패하므로,
#   MiniPC/root에서 user key와 /etc/ssh/ssh_host_ed25519_key를 둘 다 -i로 넘겨 rekey한다.
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
  # 부팅 의존 시크릿(SA token 등)은 host key 전용 — user 로그인 키 노출 표면과 분리
  minipcHostOnly = [ constants.hostKeys.minipc ];
in
{
  # sharing-text 스킬의 수동 push 함수가 사용하는 Pushover credentials
  # (이전에는 Claude Code/Codex hook 알림과 공유. native push 도입으로 hook은 제거됨.)
  "pushover-share.age".publicKeys = allHosts;
  "pane-note-links.age".publicKeys = allHosts;

  # Immich PostgreSQL 비밀번호
  "immich-db-password.age".publicKeys = minipcOnly;

  # Immich CLI 업로드 (FolderAction)
  "immich-api-key.age".publicKeys = allHosts;
  "pushover-immich.age".publicKeys = allHosts;

  # FolderActions 실패 알림 (compress-video, convert-video-to-gif,
  # rename-asset, compress-rar 공유) — Darwin 전용 소비, macbook 키만 부여
  "pushover-folder-actions.age".publicKeys = [ constants.sshKeys.macbook ];

  # Shottr 라이센스 키 (kc-license + kc-vault pre-fill)
  "shottr-license.age".publicKeys = allHosts;

  # Copyparty 파일 서버 비밀번호
  "copyparty-password.age".publicKeys = minipcOnly;

  # Vaultwarden 관리자 패널 토큰
  "vaultwarden-admin-token.age".publicKeys = minipcOnly;

  # Caddy HTTPS 인증서 발급용 Cloudflare DNS API 토큰
  "cloudflare-dns-api-token.age".publicKeys = minipcOnly;

  # 서비스 업데이트 알림용 Pushover credentials
  "pushover-uptime-kuma.age".publicKeys = minipcOnly;
  "pushover-copyparty.age".publicKeys = minipcOnly;
  "pushover-vaultwarden.age".publicKeys = minipcOnly;

  # Karakeep (웹 아카이버/북마크 관리)
  "karakeep-nextauth-secret.age".publicKeys = minipcOnly;
  "karakeep-meili-master-key.age".publicKeys = minipcOnly;
  "karakeep-openai-key.age".publicKeys = allHosts;
  "pushover-karakeep.age".publicKeys = allHosts;

  # 시스템 하드웨어 모니터링용 Pushover credentials (smartd, 향후 온도 경고 등)
  "pushover-system-monitor.age".publicKeys = minipcOnly;

  # 1Password Service Account token (opnix가 systemd EnvironmentFile로 주입)
  # host key 전용(minipcHostOnly)으로 user 로그인 키 노출 표면과 격리 (PRD #780 host key 복호화 계약).
  # 부팅 시 minipc root가 /etc/ssh/ssh_host_ed25519_key로 복호화.
  # 토큰 실제 암호화는 1Password SA 발급 후 agenix -e로 수행 (host key recipient)
  # 실 소비(opnix module) + 90일 rotation timer는 Phase 3
  "opnix-service-account-token.age".publicKeys = minipcHostOnly;

  # Mac 전용 1Password Service Account token (#872, epic #780 Phase 2b)
  # 로그인 셸 _gh_pat()이 이 SA token으로 github-pat을 per-user temp 캐시에 무인 발급 (방식 B, launchd 비의존).
  # 개인 Mac user 로그인 키 전용 recipient — work role 호스트는 복호화 불가하여 graceful 분리.
  # MiniPC host-key SA(위 minipcHostOnly)와 별개로 발급된 격리 SA (blast radius 분리, Automation read-only).
  "opnix-service-account-token-mac.age".publicKeys = [ constants.sshKeys.macbook ];
}
