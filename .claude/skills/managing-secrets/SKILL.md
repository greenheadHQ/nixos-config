---
name: managing-secrets
description: |
  Use this skill when the user asks about agenix secrets,
  .age file encryption/decryption, re-encryption, or secret key management.
  Triggers: "add a secret", "create .age file", "encrypt with agenix",
  "decrypt secret", "agenix -e", "/dev/stdin" errors, "secrets.nix",
  "re-encrypt", "age key", "identity path" issues, "시크릿", "암호화",
  "shottr-license", "shottr 라이센스".
  For service-specific secret usage, see the respective service skill.
---

# Secret 관리 (agenix)

agenix를 사용한 `.age` 파일 기반 secret 암호화/배포 가이드.

## Known Issues

**Claude Code에서 `agenix -e` 실패 (`/dev/stdin` 에러)**
- `agenix -e`는 interactive 에디터를 사용하므로 non-interactive 환경에서 실패
- 해결: `age` CLI pipe 패턴 사용 (아래 "Secret 추가/수정" 참조)
- 상세: [references/troubleshooting.md](references/troubleshooting.md)

## 빠른 참조

### 설정 파일 구조

| 파일 | 역할 |
|------|------|
| `secrets/secrets.nix` | secret 선언 + 암호화 대상 공개키 (constants.nix import) |
| `secrets/<name>.age` | 암호화된 secret 파일 (Git 추적) |
| `libraries/constants.nix` | SSH 공개키 단일 소스 (secrets.nix에서 참조) |
| `modules/shared/programs/secrets/default.nix` | 배포 경로 + 권한 설정 (Home Manager 레벨) |
| `modules/nixos/programs/docker/immich.nix` | 시스템 레벨 시크릿 (NixOS agenix) |

### agenix 레벨 구분

| 레벨 | 설정 위치 | 기본 배포 경로 | 용도 |
|------|----------|---------------|------|
| Home Manager | `modules/shared/programs/secrets/default.nix` | 사용자 지정 경로 (`~/.config/...`) | Pushover, pane-note 등 사용자 레벨 |
| NixOS 시스템 | 각 서비스 모듈 (`immich.nix`, `smartd.nix`, `temp-monitor/` 등) | `/run/agenix/<secret-name>` | immich-db-password, pushover-system-monitor 등 시스템 서비스 |

두 레벨이 공존하며, NixOS 시스템 레벨은 `flake.nix`에서 `inputs.agenix.nixosModules.default`로 활성화.
서비스 모듈에서는 하드코딩 대신 `config.age.secrets.<name>.path`를 참조해 실제 경로를 사용한다.

Secret 형식은 shell 변수 (`KEY=value`)로, 사용처에서 `source`로 로드한다.
배포 권한은 `0400` mode이며, agenix가 복호화하여 지정 경로에 배치한다.

### 현재 등록된 Secret 목록

| Secret | 배포 경로 | 용도 |
|--------|----------|------|
| `pushover-claude-code.age` | `~/.config/pushover/claude-code` | Claude Code 알림 |
| `pushover-atuin.age` | `~/.config/pushover/atuin` | Atuin 동기화 알림 |
| `pushover-immich.age` | `~/.config/pushover/immich` | Immich FolderAction 업로드 알림 |
| `pane-note-links.age` | `~/.config/pane-note/links.txt` | Pane Notepad 링크 |
| `immich-api-key.age` | `~/.config/immich/api-key` | Immich CLI 업로드 인증 |
| `immich-db-password.age` | `/run/agenix/immich-db-password` | Immich PostgreSQL 비밀번호 |
| `pushover-system-monitor.age` | `/run/agenix/pushover-system-monitor` | 시스템 하드웨어 모니터링 Pushover (smartd + temp-monitor) |
| `pushover-uptime-kuma.age` | `/run/agenix/pushover-uptime-kuma` | Uptime Kuma 업데이트 알림 |
| `pushover-copyparty.age` | `/run/agenix/pushover-copyparty` | Copyparty 업데이트 알림 |
| `anki-sync-password.age` | `/run/agenix/anki-sync-password` | Anki Sync Server 비밀번호 |
| `copyparty-password.age` | `/run/agenix/copyparty-password` | Copyparty 파일 서버 비밀번호 |
| `vaultwarden-admin-token.age` | `/run/agenix/vaultwarden-admin-token` | Vaultwarden 관리자 패널 토큰 |
| `shottr-license.age` | `~/.config/shottr/license` | Shottr 라이센스 pre-fill (`KC_LICENSE` + `KC_VAULT`) |
| `cloudflare-dns-api-token.age` | `/run/agenix/cloudflare-dns-api-token` | Caddy HTTPS 인증서 발급용 |

상세는 `secrets/secrets.nix` 참조.

### Secret 추가/수정

**추가** 워크플로 (3단계):

1. `secrets/secrets.nix`에 선언 추가
2. `.age` 파일 생성 (암호화 방법은 [references/workflows.md](references/workflows.md) 참조)
3. `modules/shared/programs/secrets/default.nix`에 배포 경로 + 권한 설정

**수정** 워크플로:

1. 기존 값 확인 (복호화 방법은 [references/workflows.md](references/workflows.md) 참조)
2. 새 내용으로 재암호화하여 `.age` 파일 덮어쓰기

**호스트 추가**: 새 호스트의 secret 접근이 필요한 경우 [references/workflows.md](references/workflows.md) 참조.

### Shottr 라이센스 pre-fill (agenix)

Shottr 라이센스 키를 agenix로 암호화하여 `nrs` 실행 시 `defaults write`로 pre-fill합니다.

Secret 파일 형식:
```
KC_LICENSE=<base64 encoded license>
KC_VAULT=<base64 encoded vault>
```

`.age` 파일 생성/갱신:
```bash
printf 'KC_LICENSE=%s\nKC_VAULT=%s\n' \
  "$(defaults read cc.ffitch.shottr kc-license)" \
  "$(defaults read cc.ffitch.shottr kc-vault)" | \
  nix shell nixpkgs#age -c age \
    -r "ssh-ed25519 <macbook-pubkey>" \
    -r "ssh-ed25519 <minipc-pubkey>" \
    -o secrets/shottr-license.age
```

HM activation이 `~/.config/shottr/license`에서 값을 읽어 `defaults write cc.ffitch.shottr kc-license -string ...`로 주입합니다.
새 맥북에서 Shottr 실행 후 Activate 버튼 1회 클릭으로 활성화됩니다.

> Shottr 크레덴셜 구조 상세는 managing-macos 스킬의 "Shottr 크레덴셜 관리 (상세)" 섹션 참조.

## 자주 발생하는 문제

1. **`agenix -e`의 `/dev/stdin` 에러**: non-interactive 환경에서 발생 → `age` CLI pipe 우회
2. **복호화 실패**: SSH 키 불일치 또는 identity path 오류
3. **재암호화 누락**: `secrets.nix`의 publicKeys 변경 후 `agenix -r` 미실행
4. **배포 후 파일 미생성**: Home Manager agenix 서비스 상태 확인, `nrs` 재실행
5. **macOS agenix crash loop (.tmp 잔류)**: `nrs`가 복호화 중인 agent를 kill → stale `.tmp` 파일이 다음 generation을 block. 예방 코드(`cleanupAgenixStaleGenerations`)가 `setupLaunchAgents` 전에 자동 정리
6. **macOS activation에서 시크릿 미발견**: agenix는 `launchd.agents`로 복호화 → `setupLaunchAgents` 이후 + polling 필요

상세는 [references/troubleshooting.md](references/troubleshooting.md) 참조.

## 레퍼런스

- 워크플로 상세 (암호화/복호화/호스트 추가): [references/workflows.md](references/workflows.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
