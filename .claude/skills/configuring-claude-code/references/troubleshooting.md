# 트러블슈팅

Claude Code 관련 문제와 해결 방법을 정리합니다.

> Codex CLI trust/.agents/skills/project-scope 이슈는 `configuring-codex` 스킬의
> `references/runbook-codex-compat.md`를 우선 참고하세요.

## 목차

- [플러그인 설치/삭제가 안 됨 (settings.json 읽기 전용)](#플러그인-설치삭제가-안-됨-settingsjson-읽기-전용)
- [PreToolUse 훅 JSON validation 에러](#pretooluse-훅-json-validation-에러)
- [Claude Code 설치 실패 (curl 미설치)](#claude-code-설치-실패-curl-미설치)
- [Pushover 알림 인코딩 깨짐 (이모지/한글이 ?로 표시)](#pushover-알림-인코딩-깨짐-이모지한글이-로-표시)

---

## 플러그인 설치/삭제가 안 됨 (settings.json 읽기 전용)

**증상**: `claude plugin uninstall` 명령 실행 시 "Plugin not found" 에러 발생. `/plugin` UI에는 설치된 것으로 표시되지만 삭제 불가.

```bash
$ claude plugin uninstall feature-dev@claude-plugins-official --scope user
Plugin not found: feature-dev
```

**원인**: `~/.claude/settings.json`이 Nix store의 읽기 전용 파일로 심볼릭 링크되어 있음.

```bash
$ ls -la ~/.claude/settings.json
lrwxr-xr-x  ... ~/.claude/settings.json -> /nix/store/xxx-claude-settings.json

$ touch ~/.claude/settings.json
touch: ~/.claude/settings.json: Permission denied
```

Claude Code는 플러그인 설치/삭제 시 `settings.json`을 수정하려고 하는데, Nix store 파일은 읽기 전용이므로 실패합니다.

**배경**: Claude Code는 런타임에 `settings.json`을 자동으로 업데이트하는 특성이 있습니다:

- 플러그인 설치/삭제
- CLI에서 설정 변경 (`claude config set ...`)
- Claude Code 버전 업데이트
- 기타 다양한 내부 동작

이는 VSCode가 GUI에서 설정 변경 시 `settings.json`을 자동 수정하는 것과 동일한 패턴입니다. 두 앱 모두 Nix의 불변(immutable) 파일 관리 방식과 충돌이 발생하므로 `mkOutOfStoreSymlink`가 필요합니다.

> **참고**: `mcp-config.json`은 Claude Code가 자동 생성하는 파일이 아닙니다. 사용자가 직접 생성/관리하며, `claude -m` 옵션으로 해당 파일을 MCP 설정으로 지정하여 사용합니다.

**해결**: `mkOutOfStoreSymlink`를 사용하여 nixos-config의 실제 파일을 직접 참조하도록 변경.

**1. `files/settings.json` 생성**

기존에 Nix에서 동적 생성하던 내용을 JSON 파일로 분리:

```bash
# modules/shared/programs/claude/files/settings.json
{
  "cleanupPeriodDays": 7,
  "alwaysThinkingEnabled": true,
  ...
}
```

**2. `default.nix` 수정**

```nix
# 변경 전: Nix store 심볼릭 링크 (읽기 전용)
".claude/settings.json".source = jsonFormat.generate "claude-settings.json" settingsContent;

# 변경 후: mkOutOfStoreSymlink (양방향 수정 가능)
".claude/settings.json".source =
  config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/settings.json";
```

**3. darwin-rebuild 실행**

```bash
nrs  # 또는 darwin-rebuild switch --flake .
```

**검증**:

```bash
# 심볼릭 링크 확인: nixos-config 경로를 가리켜야 함
$ ls -la ~/.claude/settings.json
lrwxr-xr-x  ... -> $HOME/<nixos-config-path>/modules/shared/programs/claude/files/settings.json

# 쓰기 권한 확인
$ touch ~/.claude/settings.json && echo "O 쓰기 가능"
O 쓰기 가능

# 플러그인 설치/삭제 테스트
$ claude plugin install typescript-lsp@claude-plugins-official --scope user
✔ Successfully installed plugin: typescript-lsp@claude-plugins-official

$ claude plugin uninstall typescript-lsp@claude-plugins-official --scope user
✔ Successfully uninstalled plugin: typescript-lsp
```

**VSCode와의 비교**:

| 항목 | VSCode | Claude Code |
|------|--------|-------------|
| 확장/플러그인 관리 | Nix로 선언적 관리 (UI에서 설치 불가) | CLI로 자유롭게 관리 |
| `settings.json` | `mkOutOfStoreSymlink` (양방향) | `mkOutOfStoreSymlink` (양방향) |
| 런타임 파일 수정 | GUI 설정 변경, 확장 설정 시 자동 수정 | 플러그인/MCP 설정 시 자동 수정 |

두 앱 모두 `settings.json`의 런타임 수정이 필요하므로 `mkOutOfStoreSymlink`를 사용합니다. 차이점은 확장/플러그인 관리 방식뿐입니다: VSCode는 확장을 Nix로 고정 관리하고, Claude Code는 플러그인을 CLI로 자유롭게 관리합니다.

> **참고**: Claude Code 설정은 `modules/shared/programs/claude/default.nix`에서 관리됩니다.

---

## PreToolUse 훅 JSON validation 에러

**증상**: Claude Code에서 git 명령어 실행 시 간헐적으로 다음 에러 발생:

```
PreToolUse:Bash hook error: JSON validation failed: Hook JSON output validation failed:
- : Invalid input
```

특히 체인 명령어(`git add && git commit && git push`) 실행 시 자주 발생.

**원인 분석**:

이 프로젝트는 lefthook 사용을 위해 git 명령어를 `nix develop -c`로 감싸는 PreToolUse 훅을 사용합니다. 문제는 두 가지입니다:

**1. 체인 명령어 처리 실패:**

```bash
# 입력
git add . && git commit -m "test" && git push

# 기존 방식 출력
nix develop -c git add . && git commit -m "test" && git push
#            └── nix 환경 ──┘ └───── 시스템 셸 (nix 환경 아님) ─────┘
```

`nix develop -c`는 첫 번째 명령어만 nix 환경에서 실행하고, `&&` 이후는 원래 셸에서 실행됩니다.

**2. JSON 이스케이프 불안정:**

```bash
# 기존 방식
wrapped_command="nix develop -c $command"
echo "{ \"command\": $(echo "$wrapped_command" | jq -R .) }"
```

커밋 메시지에 따옴표, 한글, 백틱, `$변수` 등 특수문자가 포함되면 JSON 이스케이프 실패.

**해결**: Base64 인코딩으로 모든 특수문자 문제 회피

```bash
# 새로운 방식
encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
wrapped_command="echo $encoded | base64 -d | nix develop -c bash"
```

**장점:**

| 항목 | 기존 방식 | Base64 방식 |
|------|----------|-------------|
| 체인 명령어 | 첫 번째만 nix 환경 | 전체가 nix 환경 O |
| 특수문자 | 이스케이프 필요 | 안전하게 처리 O |
| JSON 출력 | 멀티라인 가능성 | 항상 단일 라인 O |
| 복잡성 | 분기 로직 필요 | 단순함 O |

**수정된 스크립트** (`.claude/scripts/wrap-git-with-nix-develop.sh`):

```bash
#!/bin/bash
set -euo pipefail

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name')

if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command=$(echo "$input" | jq -r '.tool_input.command // empty')

if [[ -z "$command" ]]; then
  exit 0
fi

# git add/commit/push/stash로 시작하고, 아직 래핑되지 않은 경우
if [[ "$command" =~ ^git[[:space:]]+(add|commit|push|stash) ]] && \
   [[ ! "$command" =~ ^nix[[:space:]]+develop ]] && \
   [[ ! "$command" =~ ^echo[[:space:]].*base64 ]]; then

  # Base64 인코딩으로 모든 특수문자 문제 회피
  encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
  wrapped_command="echo $encoded | base64 -d | nix develop -c bash"

  jq -n \
    --arg cmd "$wrapped_command" \
    --arg msg "lefthook 사용을 위해 nix develop 환경에서 실행합니다." \
    '{
      hookSpecificOutput: {
        permissionDecision: "allow",
        updatedInput: { command: $cmd }
      },
      systemMessage: $msg
    }'
  exit 0
fi

exit 0
```

**검증**:

```bash
# 1. 체인 명령어 테스트
echo '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"test\""}}' | \
  bash .claude/scripts/wrap-git-with-nix-develop.sh | jq .

# 2. 한글 메시지 테스트
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: 새로운 기능\""}}' | \
  bash .claude/scripts/wrap-git-with-nix-develop.sh | jq .

# 3. Base64 디코딩 검증
output=$(echo '{"tool_name":"Bash","tool_input":{"command":"git add . && git commit -m \"test\""}}' | \
  bash .claude/scripts/wrap-git-with-nix-develop.sh)
encoded=$(echo "$output" | jq -r '.hookSpecificOutput.updatedInput.command' | sed 's/echo \([^ ]*\) |.*/\1/')
echo "$encoded" | base64 -d
# 출력: git add . && git commit -m "test"
```

**롤백**:

문제 발생 시 훅을 일시 비활성화할 수 있습니다:

```bash
# Bash PreToolUse 훅 비활성화 (백업 생성 후 settings.json 수정)
cp modules/shared/programs/claude/files/settings.json \
  modules/shared/programs/claude/files/settings.json.bak
jq 'if .hooks and .hooks.PreToolUse
    then .hooks.PreToolUse |= map(select(.matcher != "Bash"))
    else .
    end' \
  modules/shared/programs/claude/files/settings.json \
  > /tmp/claude-settings.json && mv /tmp/claude-settings.json modules/shared/programs/claude/files/settings.json

# 또는 원본 스크립트 복구
git checkout .claude/scripts/wrap-git-with-nix-develop.sh
```

**디버깅**:

스크립트에 디버그 로깅을 활성화하여 문제를 진단할 수 있습니다:

```bash
# .claude/scripts/wrap-git-with-nix-develop.sh 11-13행 주석 해제
exec 2>>/tmp/claude-hook-debug.log
echo "=== $(date) ===" >&2
echo "Input: $input" >&2

# 로그 확인
tail -f /tmp/claude-hook-debug.log
```

> **참고**: PreToolUse 훅은 `~/.claude/hooks/` 디렉토리에서 관리됩니다. 훅 설정 방법은 Claude Code 공식 문서를 참고하세요.

---

## Claude Code 설치 실패 (curl 미설치)

> **발생 시점**: NixOS 초기 설치 시

**증상**: `nixos-rebuild switch` 시 Claude Code 설치 단계에서 실패.

```
Installing Claude Code binary...
Either curl or wget is required but neither is installed
```

**원인**: Home Manager activation 스크립트에서 `${pkgs.curl}/bin/curl`을 사용하는데, `curl`이 `home.packages`에 포함되지 않음.

```nix
# 문제의 코드 (modules/shared/programs/claude/default.nix)
home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
'';
```

**해결**: `home.packages`에 `curl` 추가

```nix
# modules/nixos/home.nix
home.packages = with pkgs; [
  curl  # Claude Code 설치에 필요
  # ... 다른 패키지들
];
```

**참고**: activation 스크립트에서 사용하는 패키지는 명시적으로 의존성에 포함되어야 합니다.

---

## Pushover 알림 인코딩 깨짐 (이모지/한글이 ?로 표시)

**증상**: Claude Code hook에서 Pushover 알림 전송 시 간헐적으로 이모지/한글이 `?`로 표시됨.

- title (하드코딩): `Claude Code [📝질문 대기]` → 항상 정상
- message (동적 생성): `🖥️ hostname`, `📁 repo`, `❓ question` → 간헐적 깨짐

특히 `ask-notification.sh`에서 발생 (stdin에서 JSON 읽는 hook).

**원인**: 두 가지 원인이 복합적으로 작용.

1. **locale 미설정**: Claude Code가 hook 실행 시 `LANG`/`LC_ALL` 환경변수가 미설정 또는 `C`/`POSIX`로 설정될 수 있음. 동적 변수 확장(`$MESSAGE`) 시 UTF-8 바이트가 손상됨.

2. **curl 옵션 혼용**: `--form-string`과 `-F`를 혼용하면 `-F`는 `multipart/form-data`를 강제하고 `--form-string`과 의미가 달라 인코딩이 불안정해짐.

**해결 (2단계)**:

**1차 (locale 강제 설정)**:

```bash
#!/usr/bin/env bash
# UTF-8 인코딩 강제 설정 (Claude Code 환경에서 LANG이 미설정될 수 있음)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
```

**2차 (curl 인코딩 방식 통일)**:

`--form-string`/`-F` 혼용을 `--data-urlencode`(`application/x-www-form-urlencoded`)로 통일:

```bash
# 변경 전: --form-string과 -F 혼용 (multipart/form-data 강제)
curl -s \
  --form-string "token=$PUSHOVER_TOKEN" \
  --form-string "user=$PUSHOVER_USER" \
  --form-string "title=Claude Code [✅작업 완료]" \
  -F "sound=jobs_done" \
  --form-string "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json > /dev/null

# 변경 후: --data-urlencode로 통일 (application/x-www-form-urlencoded)
curl -s -X POST \
  -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
  --data-urlencode "token=$PUSHOVER_TOKEN" \
  --data-urlencode "user=$PUSHOVER_USER" \
  --data-urlencode "title=Claude Code [✅작업 완료]" \
  --data-urlencode "sound=jobs_done" \
  --data-urlencode "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json > /dev/null
```

**추가 안정화** (stdin 읽는 hook의 경우):

`echo` 대신 `printf '%s'` 사용:

```bash
# 변경 전
FIRST_QUESTION=$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // empty')

# 변경 후
FIRST_QUESTION=$(printf '%s' "$INPUT" | jq -r '.tool_input.questions[0].question // empty')
```

`echo`는 플랫폼/셸에 따라 escape sequence 처리가 다르지만, `printf '%s'`는 입력을 그대로 전달.

**적용 파일**:

| 파일 | 수정 내용 |
|------|----------|
| `stop-notification.sh` | locale 설정 + curl `--data-urlencode` 통일 + `--max-time 4` + 말줄임표(…) |
| `ask-notification.sh` | locale 설정 + printf 변경 + curl `--data-urlencode` 통일 |
| `plan-notification.sh` | locale 설정 + curl `--data-urlencode` 통일 + `--max-time 4` + plan 파일 읽기 + 말줄임표(…) |

**검증**:

```bash
# AskUserQuestion 트리거하여 iOS Pushover 알림 확인
# 다양한 문자 테스트: CJK, Thai, Arabic, Emoji, ZWJ sequences 등
```

> **참고**: hook 파일은 `modules/shared/programs/claude/files/hooks/`에서 관리됩니다.
