# Claude Code 설정

Claude Code CLI 도구의 설정을 Nix로 선언적으로 관리하면서, 런타임 수정(플러그인 설치/삭제, 설정 변경)도 지원합니다.

## 목차

- [관리 구조](#관리-구조)
- [양방향 수정](#양방향-수정)
- [플러그인 관리](#플러그인-관리)
- [플러그인 주의사항](#플러그인-주의사항)
- [PreToolUse 훅 (nix develop 환경)](#pretooluse-훅-nix-develop-환경)

---

`modules/shared/programs/claude/`에서 관리됩니다.

## 관리 구조

| 항목            | 관리 방식             | 설명                                        |
| --------------- | --------------------- | ------------------------------------------- |
| 앱 설치         | `home.activation`     | 설치 스크립트 실행                           |
| `settings.json` | `mkOutOfStoreSymlink` | 양방향 수정 가능                             |
| `mcp.json`      | `mkOutOfStoreSymlink` | 양방향 수정 가능                             |
| hooks           | `mkOutOfStoreSymlink` | 양방향 수정 가능 (소스 파일에 chmod +x 필수) |

## 양방향 수정

`settings.json`과 `mcp.json`은 `mkOutOfStoreSymlink`를 사용하여 nixos-config 저장소의 실제 파일을 직접 참조합니다.

**심볼릭 링크 구조:**

```
~/.claude/settings.json
    ↓ (symlink)
$HOME/<nixos-config-path>/modules/shared/programs/claude/files/settings.json
```

**장점:**

- **Claude Code → nixos-config**: 플러그인 설치, 설정 변경 시 nixos-config에 바로 반영
- **nixos-config → Claude Code**: 파일 직접 수정 후 즉시 적용 (rebuild 불필요)
- **버전 관리**: `git diff`로 변경사항 확인 후 커밋 가능

**왜 이 방식인가?**

| 방식                    | 플러그인 관리  | 설정 수정 | 문제점                                      |
| ----------------------- | -------------- | --------- | ------------------------------------------- |
| Nix store 심볼릭 링크   | 불가           | 불가      | 읽기 전용이라 CLI로 플러그인 설치/삭제 불가 |
| **mkOutOfStoreSymlink** | CLI로 자유롭게 | 양방향    | 없음                                        |

> **참고**: Cursor의 `settings.json`, `keybindings.json`도 동일한 방식으로 관리됩니다.

## 플러그인 관리

`mkOutOfStoreSymlink` 방식으로 전환 후 플러그인을 CLI로 자유롭게 관리할 수 있습니다.

**플러그인 설치:**

```bash
claude plugin install <plugin-name>@<marketplace> --scope user
```

**플러그인 제거:**

```bash
claude plugin uninstall <plugin-name>@<marketplace> --scope user
```

**플러그인 목록 확인:**

```bash
claude plugin list
```

**UI로 관리:**

Claude Code 내에서 `/plugin` 명령으로 설치된 플러그인을 확인하고 관리할 수 있습니다.

## 플러그인 주의사항

**유령 플러그인 문제 (Claude Code 2.1.4 기준):**

Claude Code에서 플러그인을 활성화/비활성화하면 `settings.json`의 `enabledPlugins` 섹션에 자동으로 기록됩니다:

```json
"enabledPlugins": {
  "frontend-design@claude-plugins-official": true
}
```

그러나 CLI 명령어(`claude plugin uninstall`)를 사용하지 않고 사용자가 직접 `settings.json`에서 해당 프로퍼티를 삭제하면, **유령 플러그인(ghost plugin) 문제**가 발생합니다:

| 상태 | 증상 |
|------|------|
| `/plugin` 명령 | 플러그인이 "설치됨"으로 표시 |
| 설정 변경 | 활성화/비활성화 토글 불가 |
| 플러그인 기능 | 동작하지 않음 |

**해결 방법:**

마켓플레이스 재설치로는 해결되지 않습니다. 유일한 방법은 `settings.json`에 유령 플러그인을 다시 명시한 후 CLI로 제거하는 것입니다:

1. `settings.json`의 `enabledPlugins`에 유령 플러그인 추가:
   ```json
   "enabledPlugins": {
     "ghost-plugin-name@marketplace": true
   }
   ```

2. Claude Code CLI로 플러그인 제거:
   ```bash
   claude plugin uninstall ghost-plugin-name@marketplace --scope user
   ```

**권장 사항:**

플러그인 설치/제거는 반드시 CLI 명령어를 사용하세요:

```bash
# 마켓플레이스 추가
claude plugin marketplace add anthropics/claude-plugins-official

# 플러그인 설치
claude plugin install plugin-name@marketplace --scope user

# 플러그인 제거
claude plugin uninstall plugin-name@marketplace --scope user
```

**Anthropic 마켓플레이스 현황 (2026-01-11 기준):**

| 마켓플레이스                       | 상태        |
| ---------------------------------- | ----------- |
| `anthropics/claude-code`           | 유지보수 X  |
| `anthropics/claude-plugins-official` | 유지보수 O |

## PreToolUse 훅 (nix develop 환경)

`.claude/scripts/wrap-git-with-nix-develop.sh`에서 관리됩니다.

이 프로젝트는 `lefthook`을 통해 git pre-commit 훅으로 `gitleaks`, `nixfmt`, `shellcheck`를 실행합니다. 이 도구들은 `nix develop` 환경에서만 사용 가능하므로, Claude Code가 git 명령어를 실행할 때 자동으로 nix develop 환경에서 실행되도록 PreToolUse 훅을 사용합니다.

**왜 필요한가:**

| 환경 | lefthook 도구 | 결과 |
|------|---------------|------|
| `nix develop` 셸 | 사용 가능 | pre-commit 훅 정상 동작 |
| 일반 시스템 셸 | 사용 불가 | pre-commit 훅 실패 또는 우회 |
| Claude Code (기본) | 사용 불가 | pre-commit 훅 실패 또는 우회 |
| Claude Code + 훅 | 사용 가능 | pre-commit 훅 정상 동작 |

**동작 방식:**

```
[Claude Code가 git 명령어 실행 요청]
        ↓
[PreToolUse 훅 (wrap-git-with-nix-develop.sh)]
        ↓
[명령어를 Base64로 인코딩]
        ↓
[nix develop -c bash로 래핑]
        ↓
[래핑된 명령어 실행]
```

**예시:**

```bash
# 원본 명령어
git add . && git commit -m "feat: 새 기능" && git push

# 래핑된 명령어
echo Z2l0IGFkZC... | base64 -d | nix develop -c bash
```

**처리 대상:**

| 명령어 | 래핑 여부 | 사유 |
|--------|----------|------|
| `git add` | O | lefthook 필요 |
| `git commit` | O | lefthook 필요 |
| `git push` | O | lefthook 필요 |
| `git stash` | O | lefthook 필요 |
| `git status` | X | lefthook 불필요 |
| `git log` | X | lefthook 불필요 |
| `ls`, `cat` 등 | X | git 명령어 아님 |

**Base64 인코딩 장점:**

- 줄바꿈, 따옴표, 백틱, `$변수`, `&&` 등 모든 특수문자 안전 처리
- 단일 라인 출력 → Claude Code 호환성 보장
- 체인 명령어(`&&`)도 전체가 nix develop 환경에서 실행됨

**설정 파일:**

```json
// .claude/settings.local.json (프로젝트별 훅 설정)
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PROJECT_DIR}/.claude/scripts/wrap-git-with-nix-develop.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

**디버깅:**

문제 발생 시 스크립트의 디버그 로깅을 활성화할 수 있습니다:

```bash
# .claude/scripts/wrap-git-with-nix-develop.sh 11-13행 주석 해제
exec 2>>/tmp/claude-hook-debug.log
echo "=== $(date) ===" >&2
echo "Input: $input" >&2
```

> **참고**: JSON validation 에러 등 훅 관련 문제는 TROUBLESHOOTING.md의 PreToolUse 훅 관련 섹션을 참고하세요.
