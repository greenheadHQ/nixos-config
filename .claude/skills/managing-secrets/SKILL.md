---
name: managing-secrets
description: |
  This skill should be used when the user asks to "add a secret",
  "create .age file", "encrypt with agenix", "decrypt secret",
  or encounters "agenix -e", "/dev/stdin" errors, "age encryption",
  "secrets.nix", "re-encrypt", "age key", "identity path" issues.
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

| 레벨 | 설정 위치 | 용도 |
|------|----------|------|
| Home Manager | `modules/shared/programs/secrets/default.nix` | Pushover, pane-note 등 사용자 레벨 |
| NixOS 시스템 | `modules/nixos/programs/docker/immich.nix` | immich-db-password 등 시스템 서비스 |

두 레벨이 공존하며, NixOS 시스템 레벨은 `flake.nix`에서 `inputs.agenix.nixosModules.default`로 활성화.

Secret 형식은 shell 변수 (`KEY=value`)로, 사용처에서 `source`로 로드한다.
배포 권한은 `0400` mode이며, agenix가 복호화하여 지정 경로에 배치한다.

### 현재 등록된 Secret 목록

| Secret | 배포 경로 | 용도 |
|--------|----------|------|
| `pushover-claude-code.age` | `~/.config/pushover/claude-code` | Claude Code 알림 |
| `pushover-atuin.age` | `~/.config/pushover/atuin` | Atuin 동기화 알림 |
| `pushover-fail2ban.age` | `~/.config/pushover/fail2ban` | Fail2ban 알림 |
| `pushover-immich.age` | `~/.config/pushover/immich` | Immich FolderAction 업로드 알림 |
| `pane-note-links.age` | `~/.config/pane-note/links.txt` | Pane Notepad 링크 |
| `immich-api-key.age` | `~/.config/immich/api-key` | Immich CLI 업로드 인증 |
| `immich-db-password.age` | (NixOS 시스템 레벨) | Immich PostgreSQL 비밀번호 |

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

## 자주 발생하는 문제

1. **`agenix -e`의 `/dev/stdin` 에러**: non-interactive 환경에서 발생 → `age` CLI pipe 우회
2. **복호화 실패**: SSH 키 불일치 또는 identity path 오류
3. **재암호화 누락**: `secrets.nix`의 publicKeys 변경 후 `agenix -r` 미실행
4. **배포 후 파일 미생성**: Home Manager agenix 서비스 상태 확인, `nrs` 재실행

상세는 [references/troubleshooting.md](references/troubleshooting.md) 참조.

## 레퍼런스

- 워크플로 상세 (암호화/복호화/호스트 추가): [references/workflows.md](references/workflows.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
