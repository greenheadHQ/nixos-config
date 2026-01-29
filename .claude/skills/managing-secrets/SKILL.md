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

현재 등록된 secret 목록은 `secrets/secrets.nix`에서 확인.

### Secret 추가/수정

**추가** 워크플로 (3단계):

1. `secrets/secrets.nix`에 선언 추가
2. `.age` 파일 생성 (아래 암호화 방법 참조)
3. `modules/shared/programs/secrets/default.nix`에 배포 경로 + 권한 설정

**수정** 워크플로:

1. 기존 값 확인 (복호화, 아래 참조)
2. 새 내용으로 재암호화하여 `.age` 파일 덮어쓰기

#### .age 파일 생성/암호화

**Interactive (터미널)** -- `agenix -e` 사용:

```bash
nix run github:ryantm/agenix -- -e secrets/<name>.age
# 에디터에서 내용 입력 후 저장 → 자동 암호화
```

추가와 수정 모두 동일한 명령으로 처리.

**Non-interactive (Claude Code)** -- `age` CLI pipe 사용:

```bash
# 1. secrets/secrets.nix에서 공개키 확인
# 2. 모든 recipient에 대해 -r 플래그 지정
printf 'KEY=value\n' | \
  nix-shell -p age --run \
  'age -r "ssh-ed25519 <key1>" -r "ssh-ed25519 <key2>" -o secrets/<name>.age'
```

`secrets/secrets.nix`의 `allHosts` 목록에 있는 모든 공개키를 `-r` 플래그로 지정해야 양쪽 호스트에서 복호화 가능.

#### 기존 secret 내용 확인 (복호화)

```bash
nix-shell -p age --run 'age -d -i ~/.ssh/id_ed25519 secrets/<name>.age'
```

### 호스트 추가

새 호스트의 secret 접근이 필요한 경우:

1. 해당 머신에서 `cat ~/.ssh/id_ed25519.pub`으로 공개키 확인
2. `secrets/secrets.nix`에 공개키 등록 및 `allHosts`에 추가
3. 재암호화: `nix run github:ryantm/agenix -- -r`

## 자주 발생하는 문제

1. **`agenix -e`의 `/dev/stdin` 에러**: non-interactive 환경에서 발생 → `age` CLI pipe 우회
2. **복호화 실패**: SSH 키 불일치 또는 identity path 오류
3. **재암호화 누락**: `secrets.nix`의 publicKeys 변경 후 `agenix -r` 미실행
4. **배포 후 파일 미생성**: Home Manager agenix 서비스 상태 확인, `nrs` 재실행

상세는 [references/troubleshooting.md](references/troubleshooting.md) 참조.

## 레퍼런스

- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
