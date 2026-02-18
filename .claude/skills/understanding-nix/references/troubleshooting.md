# 트러블슈팅

Nix 공통 이슈 (flake, experimental features, 빌드 속도, Home Manager) 관련 문제와 해결 방법을 정리합니다.

## 목차

- [git commit 시 gitleaks/lefthook not found](#git-commit-시-gitleakslefthook-not-found)
- [direnv allow 후에도 환경 활성화 안 됨](#direnv-allow-후에도-환경-활성화-안-됨)
- [darwin-rebuild 빌드 속도가 느림](#darwin-rebuild-빌드-속도가-느림)
- [experimental Nix feature 'nix-command' is disabled](#experimental-nix-feature-nix-command-is-disabled)
- [flake 변경이 인식되지 않음](#flake-변경이-인식되지-않음)
- [상세 에러 확인](#상세-에러-확인)
- [home.file의 recursive + executable이 작동하지 않음](#homefile의-recursive--executable이-작동하지-않음)
- [builtins.toJSON이 한 줄로 생성됨](#builtinstojson이-한-줄로-생성됨)
- [동적 링크 바이너리 실행 불가 (nix-ld)](#동적-링크-바이너리-실행-불가-nix-ld)
- [flake 시스템에서 /etc/nixos/configuration.nix 직접 수정 시 문제](#flake-시스템에서-etcnixosconfigurationnix-직접-수정-시-문제)

---

## git commit 시 gitleaks/lefthook not found

**에러 메시지:**

```
gitleaks: command not found
```

또는

```
lefthook: command not found
```

**원인:** `gitleaks`, `lefthook` 등 pre-commit hook 도구들이 `flake.nix`의 `devShell`에만 설치되어 있음. direnv 환경이 활성화되지 않은 상태에서 커밋 시도.

**해결:**

```bash
# 1. 프로젝트 디렉토리에서 direnv 허용
cd ~/Workspace/nixos-config
direnv allow

# 2. 환경 활성화 확인
which gitleaks
# /nix/store/xxx-gitleaks-x.x.x/bin/gitleaks

# 3. 다시 커밋 시도
git commit -m "message"
```

**direnv가 설치되지 않은 경우:**

```bash
# nrs 실행하여 direnv 설치
echo "Y" | nrs

# 터미널 재시작 (zsh hook 로드)
exec zsh

# 다시 direnv allow
direnv allow
```

---

## direnv allow 후에도 환경 활성화 안 됨

**증상:** `direnv allow` 실행 후에도 `direnv: loading .envrc` 메시지가 안 나오거나 devShell 도구에 접근 불가

**원인 1: zsh hook이 로드되지 않음**

```bash
# 확인
grep direnv ~/.zshrc

# 없으면 터미널 재시작 또는 nrs 재실행
exec zsh
```

**원인 2: .envrc 파일이 없거나 내용이 잘못됨**

```bash
# 확인
cat .envrc
# 출력: use flake

# 없으면 생성
echo "use flake" > .envrc
direnv allow
```

**원인 3: 캐시 문제**

```bash
# 캐시 삭제 후 재로드
rm -rf .direnv
direnv reload
```

**원인 4: SSH로 접속한 NixOS 서버**

SSH 접속 시 interactive shell이 아닐 수 있음:

```bash
# TTY 할당하여 접속
ssh -t greenhead-minipc

# 또는 login shell 실행
bash -l
```

---

## darwin-rebuild 빌드 속도가 느림

**증상**: `darwin-rebuild switch` 실행 시 특정 호스트에서 비정상적으로 오래 걸림

```
# 예시: 동일한 설정인데 호스트마다 속도 차이
집 맥북 (M1 Max): ~1분
회사 맥북 (M3 Pro): ~3-5분
```

**원인 분석**:

`darwin-rebuild`는 다음 단계를 거칩니다:

| 단계 | 설명 | 소요 시간 |
|------|------|----------|
| 1. flake input 확인 | GitHub에 접속하여 새 버전 확인 | ~1-2분 |
| 2. substituter 확인 | cache.nixos.org에서 패키지 확인 | ~30초 |
| 3. 빌드 | 로컬에서 derivation 빌드 | ~10초 |

대부분의 시간이 **네트워크 I/O**에 소비됩니다 (CPU 사용률이 6% 정도로 매우 낮음).

**진단 방법**:

```bash
# 1. CPU 사용률 확인 (낮으면 I/O 병목)
time sudo darwin-rebuild switch --flake .
# 출력 예: 5.73s user 5.97s system 6% cpu 2:56.01 total
#          ↑ CPU 시간은 12초, 총 시간은 3분 → I/O 대기가 대부분

# 2. 네트워크 속도 테스트
curl -o /dev/null -s -w '%{time_total}' https://api.github.com/rate_limit
curl -o /dev/null -s -w '%{time_total}' https://cache.nixos.org/nix-cache-info

# 3. 캐시 상태 확인
ls -d /nix/store/*-source 2>/dev/null | wc -l
```

**해결 방법**:

**방법 1: `--offline` 플래그 사용 (가장 효과적)**

```bash
# flake.lock이 동기화되어 있고, 새 패키지가 없는 경우
sudo darwin-rebuild switch --flake . --offline

# 또는 alias 사용
nrs-offline
```

- 네트워크 요청 없이 로컬 캐시만 사용
- **속도**: 3분 -> 10초 (약 18배 향상)

**방법 2: 병렬 다운로드 설정 증가**

`modules/shared/configuration.nix`:

```nix
nix.settings = {
  max-substitution-jobs = 128;  # 기본값 16
  http-connections = 50;        # 기본값 25
};
```

**방법 3: GitHub 토큰 설정 (rate limit 해제)**

```bash
mkdir -p ~/.config/nix
echo 'access-tokens = github.com=ghp_YOUR_TOKEN' >> ~/.config/nix/nix.conf
```

**권장 워크플로우**:

```bash
# 1. 한 호스트에서 flake update 후 push
nix flake update
nrs  # 또는 sudo darwin-rebuild switch --flake .
git add flake.lock && git commit -m "update" && git push

# 2. 다른 호스트에서 pull 후 offline rebuild
git pull
nrs-offline  # ~10초 완료!
```

> **참고**: `nrs`, `nrs-offline`, `nrp` alias는 `modules/shared/programs/shell/default.nix`에서 정의됩니다.

---

## experimental Nix feature 'nix-command' is disabled

**에러 메시지**:
```
error: experimental Nix feature 'nix-command' is disabled; add '--extra-experimental-features nix-command' to enable it
```

**원인**: Nix의 새로운 명령어(`nix run`, `nix develop` 등)와 flakes 기능은 기본적으로 비활성화되어 있습니다.

**해결**:

**방법 1: 임시 활성화 (일회성)**
```bash
nix --extra-experimental-features "nix-command flakes" run nix-darwin -- switch --flake .
```

**방법 2: 영구 활성화 (권장)**
```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

이후에는 옵션 없이 사용 가능:
```bash
nix run nix-darwin -- switch --flake .
```

---

## flake 변경이 인식되지 않음

Nix flakes는 git으로 추적되는 파일만 인식합니다:
```bash
git add <changed-files>
darwin-rebuild switch --flake .
```

---

## 상세 에러 확인

```bash
darwin-rebuild switch --flake . --show-trace
```

---

## home.file의 recursive + executable이 작동하지 않음

`recursive = true`와 `executable = true`를 함께 사용하면 실행 권한이 적용되지 않습니다:

```nix
# X 작동 안 함
".claude/hooks" = {
  source = "${claudeDir}/hooks";
  recursive = true;
  executable = true;  # 무시됨
};

# O 해결: 개별 파일로 지정
".claude/hooks/stop-notification.sh" = {
  source = "${claudeDir}/hooks/stop-notification.sh";
  executable = true;
};
```

---

## builtins.toJSON이 한 줄로 생성됨

**문제**: `home.file.".config/app/settings.json".text = builtins.toJSON { ... }`를 사용하면 JSON이 minified(한 줄)로 생성됩니다.

**원인**: `builtins.toJSON`은 공백/줄바꿈 없이 compact JSON을 생성합니다.

**해결**: `pkgs.formats.json`을 사용하여 pretty-printed JSON 생성:

```nix
let
  jsonFormat = pkgs.formats.json { };
  settingsContent = {
    key1 = "value1";
    key2 = true;
  };
in
{
  home.file.".config/app/settings.json".source =
    jsonFormat.generate "settings.json" settingsContent;
}
```

**차이점**:
- `builtins.toJSON`: `{"key1":"value1","key2":true}` (한 줄)
- `pkgs.formats.json`: 들여쓰기와 줄바꿈이 포함된 readable JSON

---

## 동적 링크 바이너리 실행 불가 (nix-ld)

> **발생 시점**: NixOS 초기 설치 시

**증상**: 외부 바이너리 (Claude Code, VS Code Server 등) 실행 시 실패.

```
Setting up Claude Code...
Could not start dynamically linked executable: /home/user/.claude/downloads/claude-x.x.x-linux-x64
NixOS cannot run dynamically linked executables intended for generic linux environments out of the box.
For more information, see: https://nix.dev/permalink/stub-ld
```

**원인**: NixOS는 FHS(Filesystem Hierarchy Standard)를 따르지 않아서 일반 Linux 바이너리를 직접 실행할 수 없습니다.

| 일반 Linux | NixOS |
|------------|-------|
| `/lib64/ld-linux-x86-64.so.2` | 존재하지 않음 |
| 동적 링크 바이너리 실행 가능 | 실행 불가 |

**해결**: `programs.nix-ld` 활성화

```nix
# modules/nixos/configuration.nix
programs.nix-ld.enable = true;
```

**nix-ld란?**

- 동적 링크된 바이너리를 NixOS에서 실행할 수 있게 해주는 호환성 레이어
- `/lib64/ld-linux-x86-64.so.2`를 시뮬레이션
- Claude Code, VS Code Server 등 외부 바이너리에 필요

**적용 후**:

```bash
$ sudo nixos-rebuild switch --flake .#hostname

# Claude Code 재설치
$ curl -fsSL https://claude.ai/install.sh | bash
✓ Claude Code successfully installed!
```

---

## flake 시스템에서 /etc/nixos/configuration.nix 직접 수정 시 문제

**증상**: `/etc/nixos/configuration.nix`를 직접 수정하고 `sudo nixos-rebuild switch`를 실행했으나 실패

```
error: file 'nixos-config' was not found in the Nix search path
```

**원인**:

이 시스템은 **flake 기반 NixOS**입니다:

| 항목 | 전통적 NixOS | Flake 기반 NixOS (현재) |
|------|-------------|----------------------|
| 설정 파일 | `/etc/nixos/configuration.nix` | `~/nixos-config/flake.nix` |
| 빌드 명령 | `nixos-rebuild switch` | `nixos-rebuild switch --flake .#hostname` |
| 설정 위치 | 로컬 | Git 저장소 |

`/etc/nixos/configuration.nix`는 flake 시스템에서 **사용되지 않는 레거시 파일**입니다. 이 파일을 수정해도 빌드에 영향이 없고, 전통적 빌드 명령은 NIX_PATH 오류를 발생시킵니다.

**해결**:

1. `/etc/nixos/configuration.nix` 수정 내용 원복
2. 설정 변경은 flake 설정 파일에서 수행:

```nix
# hosts/greenhead-minipc/default.nix 또는 관련 모듈
i18n.defaultLocale = "ko_KR.UTF-8";
```

3. flake 기반 빌드:
```bash
sudo nixos-rebuild switch --flake .#hostname
```

**교훈**:

- NixOS에서 설정 변경 시 반드시 flake 기반 명령 사용
- AI 어시스턴트 사용 시 flake 시스템임을 먼저 알려주기
- 설정 변경은 nixos-config 레포에서 수정 → push → miniPC에서 pull 후 빌드가 안전함
