# Nix 공통 기능

macOS와 NixOS에서 공통으로 사용되는 Nix 관련 기능입니다.

## 목차

- [direnv + nix-direnv](#direnv--nix-direnv)
- [Pre-commit Hooks](#pre-commit-hooks)
- [darwin-rebuild Alias](#darwin-rebuild-alias)
- [패키지 변경사항 미리보기 (nvd)](#패키지-변경사항-미리보기-nvd)
- [병렬 다운로드 최적화](#병렬-다운로드-최적화)

---

`modules/shared/configuration.nix`와 `modules/shared/programs/shell/default.nix`에서 관리됩니다.

## direnv + nix-direnv

`modules/shared/programs/direnv/default.nix`에서 관리됩니다.

프로젝트 디렉토리 진입 시 devShell 환경을 자동으로 활성화합니다.

**개념:**

| 도구 | 설명 |
|------|------|
| **direnv** | 디렉토리별 환경 변수 자동 로드/언로드 |
| **nix-direnv** | direnv의 Nix 확장. `use flake` 지원 + 결과 캐싱 |

**설정:**

```nix
# modules/shared/programs/direnv/default.nix
programs.direnv = {
  enable = true;
  enableZshIntegration = true;
  nix-direnv.enable = true;
};
```

**사용법:**

```bash
# 1. 프로젝트 루트에 .envrc 파일 생성
echo "use flake" > .envrc

# 2. direnv 허용 (보안상 최초 1회 필요)
direnv allow

# 3. 이후 디렉토리 진입 시 자동 활성화
cd ~/IdeaProjects/nixos-config
# direnv: loading .envrc
# direnv: using flake
# direnv: nix-direnv: Using cached dev shell
```

**동작 흐름:**

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

**nix-direnv 캐싱:**

- devShell 평가 결과를 `.direnv/` 디렉토리에 캐싱
- flake.lock 변경 시에만 재평가 (평소에는 즉시 로드)
- 첫 로드: ~수 초 / 이후 로드: ~100ms

**Pre-commit Hooks와의 관계:**

| 환경 | 상태 |
|------|------|
| direnv 환경 내 | gitleaks, lefthook 등 devShell 도구 사용 가능 |
| direnv 환경 외 | devShell 도구 접근 불가 → hook 실패 |

> **참고**: nixos-config 프로젝트의 `.envrc`는 Git에 커밋되어 있으므로 `direnv allow`만 실행하면 됩니다.

## Pre-commit Hooks

`flake.nix`의 `devShells`와 `lefthook.yml`에서 관리됩니다.

lefthook을 사용하여 커밋 전 자동 검사를 수행합니다. 민감 정보 유출, 포맷 오류, 쉘 스크립트 문제를 커밋 단계에서 차단합니다.

**구성 요소:**

| Hook | 도구 | 기능 |
|------|------|------|
| gitleaks | `gitleaks protect --staged` | 민감 정보(API 키, 비밀번호 등) 커밋 차단 |
| nixfmt | `nixfmt --check` | Nix 파일 포맷 검사 |
| shellcheck | `shellcheck -S warning` | Shell 스크립트 린팅 (warning 이상) |

**사용법:**

```bash
# devShell 진입 (lefthook 자동 설치)
nix develop

# 이후 커밋 시 자동 실행
git commit -m "message"
```

**gitleaks 허용 목록 (.gitleaks.toml):**

| 경로 | 사유 |
|------|------|
| `flake.lock` | 해시값이 시크릿으로 오탐지됨 |
| `*.local.md` | 로컬 전용 문서 (커밋 안 함) |

**탐지 예시:**

```bash
# 차단됨 (Private Key)
-----BEGIN RSA PRIVATE KEY-----

# 차단됨 (실제 형태의 AWS Access Key)
AKIAIOSFODNN7TESTKEY

# 허용됨 (AWS 예시 키 - EXAMPLE로 끝남)
AKIAIOSFODNN7EXAMPLE
```

**gitleaks 내장 allowlist 패턴:**

gitleaks는 `aws-access-token` 규칙에 다음 [내장 allowlist](https://github.com/gitleaks/gitleaks/blob/master/config/gitleaks.toml)를 포함합니다:

```toml
[rules.allowlist]
regexes = [
    '''.+EXAMPLE$''',
]
```

이 패턴은 `EXAMPLE`로 끝나는 모든 문자열을 허용합니다. AWS 공식 문서에서 사용하는 예시 키(`AKIAIOSFODNN7EXAMPLE`)가 false positive로 탐지되는 것을 방지하기 위함입니다.

| 키 | 탐지 여부 | 사유 |
|----|----------|------|
| `AKIAIOSFODNN7EXAMPLE` | 허용 | `EXAMPLE`로 끝남 |
| `AKIA222222222EXAMPLE` | 허용 | `EXAMPLE`로 끝남 |
| `AKIAIOSFODNN7TESTKEY` | **차단** | `EXAMPLE`로 끝나지 않음 |
| `AKIAIOSFODNN7REALKEY` | **차단** | `EXAMPLE`로 끝나지 않음 |

> **주의**: 실제 키를 `...EXAMPLE` 형태로 위장하면 탐지를 우회할 수 있으므로, PR 리뷰 시 주의가 필요합니다.

**주의사항:**

- direnv 환경이 활성화되지 않은 상태에서 커밋 시 hook이 실패함
  - 해결: `direnv allow` 실행 또는 `nix develop` 진입
- 새 스크립트 추가 시 `shellcheck -S warning`으로 사전 검사 권장

## darwin-rebuild Alias

시스템 설정 적용을 위한 편리한 alias입니다.

| Alias         | 용도                                        |
| ------------- | ------------------------------------------- |
| `nrs`         | 일반 rebuild (미리보기 + 확인 + 적용) |
| `nrs-offline` | 오프라인 rebuild (빠름, 동일한 안전 조치 포함) |
| `nrp`         | 미리보기만 (적용 안 함) |
| `nrp-offline` | 오프라인 미리보기 |
| `nrh`         | 최근 10개 세대 히스토리 (빠름) |
| `nrh -n 20`   | 최근 20개 세대 히스토리 |
| `nrh -a`      | 전체 세대 히스토리 (느림) |
| `hs`          | Hammerspoon CLI                             |
| `hsr`         | Hammerspoon 설정 리로드 (완료 시 알림 표시) |
| `reset-term`  | 터미널 CSI u 모드 리셋 (문제 발생 시 복구)  |

**`nrs` / `nrs-offline` 동작 흐름:**

```
1. launchd 에이전트 정리 (setupLaunchAgents 멈춤 방지)
   └── com.green.* 에이전트 동적 탐색 → bootout + plist 삭제

2. darwin-rebuild build + nvd diff (미리보기)
   └── 빌드 실패 시 즉시 종료 (에러 처리)

3. darwin-rebuild switch 실행
   └── --offline 플래그 (nrs-offline만)

4. Hammerspoon 완전 재시작 (HOME 오염 방지)
   └── killall → sleep 1 → open -a Hammerspoon

5. 빌드 아티팩트 정리
   └── ./result* 심볼릭 링크 삭제
```

**구현:**

- 스크립트: `scripts/nrs.sh`, `scripts/nrp.sh`, `scripts/nrh.sh`
- 설치 위치: `~/.local/bin/nrs.sh`, `~/.local/bin/nrp.sh`, `~/.local/bin/nrh.sh`
- alias: `nrs` → `~/.local/bin/nrs.sh`, `nrs-offline` → `~/.local/bin/nrs.sh --offline`

에이전트 목록은 하드코딩하지 않고 `launchctl list | grep com.green`으로 동적 탐색합니다.

**사용 시나리오:**

```bash
# 평소 (설정만 변경, flake.lock 동기화된 상태)
nrs-offline  # ~10초 완료!

# 새 패키지 추가 또는 flake update 후
nrs          # 일반 모드 (다운로드 필요)
```

**`--offline` 플래그의 의미:**

- 네트워크 요청을 하지 않고 로컬 캐시(`/nix/store`)만 사용
- flake input 버전 확인, substituter 확인 등을 스킵
- **속도 향상**: 일반 모드 ~3분 → 오프라인 모드 ~10초 (약 18배 빠름)

**소스 참조 방식 (로컬 vs Remote):**

> **중요**: `nrs`와 `nrs-offline` **모두** `flake.lock`에 잠긴 **Remote Git URL**에서 소스를 참조합니다.

| 항목 | 설명 |
|------|------|
| 소스 위치 | `flake.lock`에 기록된 remote Git URL (SSH) |
| 로컬 경로 | 사용하지 않음 (`path:...` 형태 아님) |
| `--offline` 역할 | 다운로드 스킵 + Nix store 캐시 사용 (로컬 경로 전환이 **아님**) |

**자동 예방 조치:**

| 문제 | 예방 방법 |
|------|----------|
| `setupLaunchAgents`에서 멈춤 | rebuild 전 launchd 에이전트 정리 |
| Hammerspoon HOME이 `/var/root`로 오염 | rebuild 후 Hammerspoon 완전 재시작 |

**주의사항:**

- `nrs-offline`은 캐시에 모든 패키지가 있어야 동작
- 새 패키지 추가 시에는 `nrs` 사용 필요
- 집/회사 간 `flake.lock`을 git으로 동기화하면 어디서든 `nrs-offline` 사용 가능

## 패키지 변경사항 미리보기 (nvd)

시스템 업데이트 전 변경사항을 미리 확인할 수 있습니다.

| 명령어 | 설명 |
|--------|------|
| `nrp` | 빌드 후 변경사항 미리보기 (적용 안 함) |
| `nrp-offline` | 오프라인 미리보기 |
| `nrh` | 최근 10개 세대 히스토리 (기본) |
| `nrh -n 5` | 최근 5개 세대 히스토리 |
| `nrh -a` | 전체 세대 히스토리 (느림) |

> **참고**: `nrs` 실행 시에도 빌드 후 변경사항을 보여주고 확인을 요청합니다.

**`nrh` 옵션:**
- `-n, --limit N`: 최근 N개 세대만 조회 (기본: 10)
- `-a, --all`: 전체 세대 조회 (세대가 많으면 느림)
- `-h, --help`: 도움말

**출력 예시:**

```
[U*] firefox: 132.0 → 133.0     # 업데이트 (*=의존성 변경)
[A]  new-package: 1.0            # 신규 추가
[R]  removed-package             # 제거
```

**권장 워크플로우:**

```bash
# 1. 집에서 flake update 후 push
nix flake update
nrs
git add flake.lock && git commit -m "update flake.lock" && git push

# 2. 회사에서 pull 후 빠른 rebuild
git pull
nrs-offline  # 네트워크 요청 없이 빠르게 빌드
```

## 병렬 다운로드 최적화

패키지 다운로드 속도를 높이기 위한 설정입니다.

**현재 설정:**

```nix
nix.settings = {
  max-substitution-jobs = 128;  # 동시 다운로드 수 (기본값: 16)
  http-connections = 50;        # 동시 HTTP 연결 수 (기본값: 25)
};
```

**효과:**

| 설정                    | 기본값 | 현재값 | 효과                         |
| ----------------------- | ------ | ------ | ---------------------------- |
| `max-substitution-jobs` | 16     | 128    | 동시에 128개 패키지 다운로드 |
| `http-connections`      | 25     | 50     | HTTP 연결 2배 증가           |

**확인 방법:**

```bash
nix config show | grep -E "(max-substitution|http-connections)"
# 출력:
# http-connections = 50
# max-substitution-jobs = 128
```

> **참고**: 공격적인 설정으로 네트워크 대역폭을 많이 사용합니다. 공유 네트워크에서 문제가 되면 값을 낮추세요.
