# Nix 공통 기능

macOS와 NixOS에서 공통으로 사용되는 Nix 관련 기능입니다.

## 목차

- [direnv + nix-direnv](#direnv--nix-direnv)
- [Pre-commit Hooks](#pre-commit-hooks)
- [Flake/Nix 기본값](#flakenix-기본값)
- [rebuild Alias (nrs)](#rebuild-alias-nrs)
- [패키지 변경사항 미리보기 (nvd)](#패키지-변경사항-미리보기-nvd)
- [병렬 다운로드 최적화](#병렬-다운로드-최적화)

---

`modules/shared/configuration.nix`와 `modules/shared/programs/shell/default.nix`에서 관리됩니다.

## direnv + nix-direnv

`modules/shared/programs/direnv/default.nix`에서 관리됩니다.

프로젝트 디렉토리 진입 시 devShell 환경을 자동으로 활성화합니다.

개념:

| 도구 | 설명 |
|------|------|
| direnv | 디렉토리별 환경 변수 자동 로드/언로드 |
| nix-direnv | direnv의 Nix 확장. `use flake` 지원 + 결과 캐싱 |

설정:

```nix
# modules/shared/programs/direnv/default.nix
programs.direnv = {
  enable = true;
  enableZshIntegration = true;
  nix-direnv.enable = true;
};
```

사용법:

```bash
# 1. 프로젝트 루트에 .envrc 파일 생성
echo "use flake" > .envrc

# 2. direnv 허용 (보안상 최초 1회 필요)
direnv allow

# 3. 이후 디렉토리 진입 시 자동 활성화
cd ~/Workspace/nixos-config
# direnv: loading .envrc
# direnv: using flake
# direnv: nix-direnv: Using cached dev shell
```

동작 흐름:

```
디렉토리 진입
    ↓
direnv가 .envrc 감지
    ↓
"use flake" 실행
    ↓
nix-direnv가 flake.nix의 devShells.default 로드
    ↓
PATH, 환경변수 등 자동 설정
    ↓
디렉토리 이탈 시 자동 해제
```

nix-direnv 캐싱:

- devShell 평가 결과를 `.direnv/` 디렉토리에 캐싱
- flake.lock 변경 시에만 재평가 (평소에는 즉시 로드)
- 첫 로드: ~수 초 / 이후 로드: ~100ms

Pre-commit Hooks와의 관계:

| 환경 | 상태 |
|------|------|
| direnv 환경 내 | gitleaks, lefthook 등 devShell 도구 사용 가능 |
| direnv 환경 외 | devShell 도구 접근 불가 → hook 실패 |

> 참고: nixos-config 프로젝트의 `.envrc`는 Git에 커밋되어 있으므로 `direnv allow`만 실행하면 됩니다.

## Pre-commit Hooks

`flake.nix`의 `devShells`와 `lefthook.yml`에서 관리됩니다.

lefthook을 사용하여 커밋 전 자동 검사를 수행합니다. 민감 정보 유출, 포맷 오류, 쉘 스크립트 문제를 커밋 단계에서 차단합니다.

구성 요소:

| Stage | Hook | 도구 | 기능 |
|-------|------|------|------|
| pre-commit | ai-skills-consistency | `bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/warn-skill-consistency.sh` | staged snapshot 기준 AI 스킬 문서 일관성 검사 |
| pre-commit | gitleaks | `bash ./scripts/ai/run-gitleaks-staged-policy.sh` | staged policy 기준 민감 정보(API 키, 비밀번호 등) 커밋 차단 |
| pre-commit | nixfmt | `nixfmt --check` | Nix 파일 포맷 검사 |
| pre-commit | shellcheck | `shellcheck -S warning` | Shell 스크립트 린팅 (warning 이상) |
| pre-commit | eval-tests | `bash ./scripts/ai/run-staged-snapshot.sh -- bash ./tests/run-eval-tests.sh` | staged snapshot 기준 NixOS 설정 E2E 보안 검증 (~1.2s) |
| pre-commit | skill-noise-check | `bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh` | staged snapshot 기준 shared skill markdown noise 검사 |
| pre-commit | local-skill-noise-check | `bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh .claude/skills` | staged snapshot 기준 local skill markdown noise 검사 |
| pre-push | flake-check | `nix flake check --no-build --all-systems` | Flake 평가 오류 검사 |

상세 hook 정책은 repo 루트 `README.md`와 `lefthook.yml`을 기준으로 한다. 직접 스크립트 실행은 installed pre-commit staged snapshot 경로와 동일하지 않다.

사용법:

```bash
# devShell 진입 (lefthook 자동 설치)
nix develop

# 이후 커밋 시 자동 실행
git commit -m "message"
```

gitleaks 허용 목록 (.gitleaks.toml):

| 경로 | 사유 |
|------|------|
| `flake.lock` | 해시값이 시크릿으로 오탐지됨 |

`.gitignore`의 `*.local.md`는 추적 금지일 뿐 gitleaks 예외가 아니다 — allowlist는 `flake.lock` 하나뿐이다.

문서용 마스킹 탐지 예시:

```bash
# 차단됨 (Private Key)
-----BEGIN RSA PRIVATE KEY-----

# AWS Access Key 형태는 탐지 대상이므로 문서에는 일부 마스킹한 예시만 둔다
AKIAIOSFODNN7TEST_KEY

# 허용됨 (AWS 예시 키 - EXAMPLE로 끝남)
AKIAIOSFODNN7EXAMPLE
```

gitleaks 내장 allowlist 패턴:

gitleaks는 `aws-access-token` 규칙에 다음 [내장 allowlist](https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml)를 포함합니다:

```toml
[rules.allowlist]
regexes = [
    '''.+EXAMPLE$''',
]
```

이 패턴은 `EXAMPLE`로 끝나는 모든 문자열을 허용합니다. AWS 공식 문서에서 사용하는 예시 키(`AKIAIOSFODNN7EXAMPLE`)가 false positive로 탐지되는 것을 방지하기 위함입니다.

| 키 | 문서 표기 | 실제 탐지 의미 |
|----|----------|---------------|
| `AKIAIOSFODNN7EXAMPLE` | 허용 예시 | `EXAMPLE`로 끝남 |
| `AKIA222222222EXAMPLE` | 허용 예시 | `EXAMPLE`로 끝남 |
| `AKIAIOSFODNN7TEST_KEY` | 마스킹 예시 | underscore 제거 시 `EXAMPLE`로 끝나지 않아 탐지 대상 |
| `AKIAIOSFODNN7REAL_KEY` | 마스킹 예시 | underscore 제거 시 `EXAMPLE`로 끝나지 않아 탐지 대상 |

> 주의: 실제 키를 `...EXAMPLE` 형태로 위장하면 탐지를 우회할 수 있으므로, PR 리뷰 시 주의가 필요합니다.

eval-tests (E2E 보안/intent 검증):

`nix eval --impure --file tests/eval-tests.nix`로 최종 NixOS config 속성을 직접 검사합니다. Nix lazy evaluation 덕분에 ~1.2초에 완료됩니다.

주요 검증 카테고리:
- NixOS 네트워크 노출 경계: homeserver 포트 충돌, 컨테이너 localhost 바인딩, publish 우회, host network allowlist
- Caddy/Tailscale 경계: virtualHost listenAddresses, default_bind, bind 우회, subdomain vhost 완전성
- SSH/방화벽 경화: openssh 설정, trustedInterfaces, TCP/UDP 포트, 인터페이스별 포트, 수동 규칙 인젝션
- 1Password/opnix materialization: vault/account 상수, SA token 권한, tmpfs secret 경로
- Darwin intent: expected host, sudo/Touch ID, Dock/keyboard 설정, zsh compinit 단일 정본

현행 전체 테스트는 `tests/eval-tests.nix`가 정본입니다. 건수와 세부 항목은 문서에 복사하지 않고 이 파일에서 확인합니다.

```bash
rg -n 'name = "Test' tests/eval-tests.nix
```

```bash
# 직접 실행
nix eval --impure --file tests/eval-tests.nix

# lefthook 통해 실행
lefthook run pre-commit
```

주의사항:

- direnv 환경이 활성화되지 않은 상태에서 커밋 시 hook이 실패함
  - 해결: `direnv allow` 실행 또는 `nix develop` 진입
- 새 스크립트 추가 시 `shellcheck -S warning`으로 사전 검사 권장
- eval-tests는 working tree 전체를 평가 (staged 파일만이 아님)

## Flake/Nix 기본값

flake input 채널:

```nix
# flake.nix
inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
```

공통 Nix 설정 (`modules/shared/configuration.nix`):

| 설정 | 값 | 목적 |
|------|----|------|
| `experimental-features` | `nix-command flakes` | Flake/Nix CLI 활성화 |
| `warn-dirty` | `false` | dirty tree 경고 숨김 |
| `optimise.automatic` | `true` | 스토어 중복 데이터 자동 정리 |
| `gc.automatic` | `true` | 자동 가비지 컬렉션 |
| `gc.options` | `--delete-older-than 30d` | 30일 지난 세대 정리 |

NixOS는 추가로 `modules/nixos/configuration.nix`에서 `nix.gc.dates = "weekly";`를 설정합니다.

## rebuild Alias (nrs)

시스템 설정 적용을 위한 편리한 alias입니다.

공통 alias:

| 명령어        | 용도                                        |
| ------------- | ------------------------------------------- |
| `nrs`         | 일반 rebuild (미리보기 + 확인 + 적용) |
| `nrs --offline` | 오프라인 rebuild (빠름, 동일한 안전 조치 포함) |
| `nrp`         | 미리보기만 (적용 안 함) |
| `nrp --offline` | 오프라인 미리보기 |

macOS 전용 alias:

| Alias         | 용도                                        |
| ------------- | ------------------------------------------- |
| `nrh`         | 최근 10개 세대 히스토리 (스크립트) |
| `nrh --all`   | 전체 세대 히스토리 (스크립트) |
| `hs`          | Hammerspoon CLI                             |
| `hsr`         | Hammerspoon 설정 리로드 (완료 시 알림 표시) |

NixOS 전용 alias:

| Alias         | 용도                                        |
| ------------- | ------------------------------------------- |
| `nrh`         | 최근 10개 세대 히스토리 (`nix-env` alias) |
| `nrh-all`     | 전체 세대 히스토리 (`nix-env` alias) |

`nrs` / `nrs --offline` 공통 동작:

```
1. 플랫폼별 rebuild build + nvd diff (미리보기)
   └── 빌드 실패 시 즉시 종료 (에러 처리)

2. 공통 preview_changes()에서 NO_CHANGES 판정 (./result와 /run/current-system store 경로 비교)
   ├── 변경 없음 (NO_CHANGES=true) → activation/switch 스킵
   │   └── nrs --force 사용 시 스킵 우회
   └── 변경 있음 (NO_CHANGES=false) → 계속 실행

3. worktree symlink guard/relink 준비
   └── 워크트리 빌드 시 out-of-store symlink 충돌을 피하도록 restore/relink 흐름 사용

4. 플랫폼별 switch 실행
   └── macOS: darwin-rebuild switch
   └── NixOS: nixos-rebuild switch (exit code 4는 transient unit failure로 경고 처리)

5. 빌드 아티팩트 정리
   └── ./result* 심볼릭 링크 삭제
```

플랫폼별 추가 처리:

- macOS: switch 전 launchd agent 정리, cask conflict preflight, switch 후 Hammerspoon 재시작
- NixOS: 소스 빌드 preflight, rebuild lock, switch 후 relink/restore
- worktree relink의 운영 전제는 repo 루트 `CLAUDE.md`의 빌드 절과 `modules/shared/scripts/lib/rebuild/relink.sh`를 기준으로 한다.

구현:

- macOS 스크립트: `modules/darwin/scripts/nrs.sh`, `modules/darwin/scripts/nrp.sh`, `modules/darwin/scripts/nrh.sh`
- NixOS 스크립트: `modules/nixos/scripts/nrs.sh`, `modules/nixos/scripts/nrp.sh`
- 공통 preview/NO_CHANGES 판정: `modules/shared/scripts/lib/rebuild/preview.sh`
- 설치 위치: `~/.local/bin/nrs`, `~/.local/bin/nrp` (macOS는 `~/.local/bin/nrh` 추가)
- PATH에 `~/.local/bin`이 포함되어 직접 실행 가능 (`nrs`, `nrs --offline`)

macOS에서는 에이전트 목록을 하드코딩하지 않고 `launchctl list | grep com.green`으로 동적 탐색합니다.

사용 시나리오:

```bash
# 평소 (설정만 변경, flake.lock 동기화된 상태)
nrs --offline  # ~10초 완료!

# 새 패키지 추가 또는 flake update 후
nrs            # 일반 모드 (다운로드 필요)
```

`--offline` 플래그의 의미:

- 네트워크 요청을 하지 않고 로컬 캐시(`/nix/store`)만 사용
- flake input 버전 확인, substituter 확인 등을 스킵
- 속도 향상: 일반 모드 ~3분 → 오프라인 모드 ~10초 (약 18배 빠름)

소스 참조 방식 (로컬 vs Remote):

> 중요: `nrs`와 `nrs --offline` 모두 `flake.lock`에 잠긴 Remote Git URL에서 소스를 참조합니다.

| 항목 | 설명 |
|------|------|
| 소스 위치 | `flake.lock`에 기록된 remote Git URL (SSH) |
| 로컬 경로 | 사용하지 않음 (`path:...` 형태 아님) |
| `--offline` 역할 | 다운로드 스킵 + Nix store 캐시 사용 (로컬 경로 전환이 아님) |

자동 예방 조치:

| 문제 | 예방 방법 |
|------|----------|
| `setupLaunchAgents`에서 멈춤 | rebuild 전 launchd 에이전트 정리 |
| Hammerspoon HOME이 `/var/root`로 오염 | rebuild 후 Hammerspoon 완전 재시작 |

주의사항:

- `nrs --offline`은 캐시에 모든 패키지가 있어야 동작
- 새 패키지 추가 시에는 `nrs` 사용 필요
- `flake.lock`이 갱신된 직후에는 보통 `--offline`을 쓸 수 없다. 새 rev의 store path가 로컬에
  없으면 `--offline`은 substituter도 건너뛰므로 실패한다. 필요한 경로가 이미 로컬 store에
  있다면(다른 호스트에서 받아뒀거나 GC 전이라면) 동작할 수도 있으나 그 조건을 미리 알기
  어려우므로, lock 갱신 후에는 온라인 `nrs`를 쓰고 `--offline`은 lock 무변경 재적용에 쓴다.

## 패키지 변경사항 미리보기 (nvd)

시스템 업데이트 전 변경사항을 미리 확인할 수 있습니다.

| 명령어 | 설명 |
|--------|------|
| `nrp` | 빌드 후 변경사항 미리보기 (적용 안 함) |
| `nrp --offline` | 오프라인 미리보기 |
| `nrh` (macOS) | 최근 10개 세대 히스토리 |
| `nrh --all` (macOS) | 전체 세대 히스토리 |
| `nrh` (NixOS) | 최근 10개 세대 (`nix-env --list-generations ...` 후 tail 10) |
| `nrh-all` (NixOS) | 전체 세대 (`nix-env ...`) |

> 참고: `nrs` 실행 시에도 빌드 후 `nvd diff`를 출력합니다.

`nrh`의 `-n`/`-a` 옵션은 macOS 스크립트(`~/.local/bin/nrh`)에서만 지원합니다.
NixOS는 alias 기반이라 `nrh`/`nrh-all` 두 명령으로 구분합니다.

출력 예시:

```
[U*] firefox: 132.0 → 133.0     # 업데이트 (*=의존성 변경)
[A]  new-package: 1.0            # 신규 추가
[R]  removed-package             # 제거
```

권장 워크플로우:

```bash
# 1. 첫 호스트에서 flake update (nfu가 update → FOD hash fix → nrs를 원자적으로 수행)
nfu
git add -u && git commit -m "chore: update flake inputs" && git push

# 2. 두 번째 호스트에서 pull 후 적용
git pull
./scripts/fix-fod-hashes.sh  # 이 플랫폼 전용 FOD hash 검증 (호스트마다 별도 필요)
nrs                          # --offline 금지: lock이 바뀌어 로컬에 없는 store path를 받아야 한다

# 3. hash가 수정됐다면 저장소로 되돌린다
git add -u && git commit -m "fix: <platform> FOD hash" && git push
```

3단계를 빠뜨리면 그 호스트의 working tree가 dirty로 남아 다음 `nfu`가 중단되고
(`nfu.sh`의 clean tree 게이트), 고친 hash가 다른 호스트로 전파되지 않습니다.

2번째 호스트에서 `nfu`를 쓰지 않는 이유: `nfu`는 `nix flake update`를 선행하므로
1번에서 검증·커밋한 lock이 다른 rev로 재갱신되어 멀티 호스트 동기화가 깨진다.

## 병렬 다운로드 최적화

패키지 다운로드 속도를 높이기 위한 설정입니다.

현재 설정:

```nix
nix.settings = {
  max-substitution-jobs = 128;  # 동시 다운로드 수 (기본값: 16)
  http-connections = 50;        # 동시 HTTP 연결 수 (기본값: 25)
  download-buffer-size = 256 * 1024 * 1024; # 다운로드 버퍼 (기본값: 64 MiB)
};
```

효과:

| 설정                    | 기본값 | 현재값  | 효과                            |
| ----------------------- | ------ | ------- | ------------------------------- |
| `max-substitution-jobs` | 16     | 128     | 동시에 128개 패키지 다운로드    |
| `http-connections`      | 25     | 50      | HTTP 연결 2배 증가              |
| `download-buffer-size`  | 64 MiB | 256 MiB | 버퍼 부족 시 다운로드 정체 방지 |

확인 방법:

```bash
nix config show | grep -E "(max-substitution|http-connections|download-buffer)"
# 출력:
# download-buffer-size = 268435456
# http-connections = 50
# max-substitution-jobs = 128
```

> 참고: 공격적인 설정으로 네트워크 대역폭을 많이 사용합니다. 공유 네트워크에서 문제가 되면 값을 낮추세요.
