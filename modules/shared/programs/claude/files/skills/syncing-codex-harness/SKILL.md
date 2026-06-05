---
name: syncing-codex-harness
description: |
  Sync Claude Code harness to Codex CLI via sync.sh.
  Trigger: 'codex sync', 'codex 동기화', '하네스 동기화', 'sync.sh'.
  NOT for codex exec (use using-codex-exec).
allowed-tools: Bash(*)
---

# Claude Code -> Codex CLI Harness Sync

이 스킬은 현재 프로젝트의 Claude Code 하니스(스킬, 에이전트, MCP, 규칙)를
Codex CLI 호환 구조(`.agents/`, `.codex/`)로 프로젝션한다.

## 목적과 범위

프로젝트의 Claude 하니스를 Codex가 인식 가능한 디렉토리/설정 구조로 동기화하는 절차를 제공한다.

## 빠른 참조

| 단계 | 명령 |
|------|------|
| 전체 동기화 | `bash "$SYNC_SH" all "$PWD" "${ARGS[@]}"` |
| 로컬 스킬만 | `bash "$SYNC_SH" project-skills "$PWD/.claude/skills" "$PWD/.agents/skills"` |
| 프로젝트 MCP 섹션만 | 아래 "MCP 섹션 가드 예시" 참조 |
| User-scope MCP 투영 | 아래 "MCP 섹션 가드 예시" 참조 |

### MCP 섹션 가드 예시

`mcp-config`는 source 옵션 없이 호출하거나 `--project-mcp`/`--plugin-mcp`/`--user-mcp` source 파일이 없으면 fail-fast한다. 선택적 source를 다루는 호출자는 불필요한 실패를 피하기 위해 `if [ -f X ]; then ...; fi` 가드를 사용한다 — `set -e` 환경에서도 안전하다.

```bash
# 프로젝트 MCP 섹션만
if [ -f "$PWD/.mcp.json" ]; then
  bash "$SYNC_SH" mcp-config "$PWD" --project-mcp="$PWD/.mcp.json"
fi

# User-scope MCP 투영
if [ -f "$HOME/.claude/mcp.json" ]; then
  bash "$SYNC_SH" mcp-config "$PWD" --user-mcp="$HOME/.claude/mcp.json"
fi
```

> 추가 동작 노트:
> - `mcp-config`는 source 옵션 (`--project-mcp` / `--plugin-mcp` / `--user-mcp`) 중 적어도 하나가 필요하다. 예외적으로 `--clear-project-mcp`는 managed project MCP 블록만 제거하는 명시적 no-source 작업이다. source 없이 호출하거나 source path 파일이 없으면 `sync.sh`가 non-zero로 종료하며 기존 `[mcp_servers.*]` 섹션을 건드리지 않는다. `--plugin-mcp`는 `PATH:INSTALL_PATH:NAME` 형식이어야 한다.
> - `all` 경로는 인자 조립 시점에 `[ -f .mcp.json ]` 가드를 두어 이 문제를 피한다.
> - `project-skills`는 `<source-skills-dir> <target-skills-dir>` 두 인자를 모두 명시해야 한다. `sync.sh`는 `set -u` 아래에서 동작하므로 한 인자만 넘기면 즉시 `unbound variable`로 실패하고 종료한다 (투영이 0개로 끝나는 게 아니라 실행 자체가 멈춘다).
> - `set -e` 가드 패턴 (단일 SoT): 위 if 가드 형태가 본 SKILL의 표준이다. 이전 `test -f X && cmd` 형태는 standalone statement 위치(함수/스크립트 마지막 또는 단독 실행)에서 false 평가 시 exit 1을 propagate해 `set -e` caller를 abort시킨다. `if` 조건 *내부*의 `[ ... ] && [ ... ]`은 단일 평가식이므로 안전하며 본 가이드의 금지 대상이 아니다.

`sync.sh` 스크립트 경로: 현재 SKILL.md가 위치한 디렉토리의 `references/sync.sh`를 사용하라.
예: 이 SKILL.md의 실제 경로가 `~/.claude/skills/syncing-codex-harness/SKILL.md`이면
`SYNC_SH=~/.claude/skills/syncing-codex-harness/references/sync.sh`

## Step 1: 소스 감지 (Detection)

프로젝트의 Claude Code 하니스 유형을 파악:

```bash
# 로컬 스킬 확인
LOCAL_SKILLS=0
if [ -d ".claude/skills" ]; then
  LOCAL_SKILLS=$(ls -d .claude/skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
fi

# 플러그인 확인
PLUGIN_KEYS=()
if [ -f ".claude/settings.local.json" ]; then
  # enabledPlugins에서 true인 키 추출
  PLUGIN_KEYS=($(python3 -c "
import json, sys
try:
  d = json.load(open('.claude/settings.local.json'))
  for k, v in d.get('enabledPlugins', {}).items():
    if v: print(k)
except: pass
" 2>/dev/null))
fi
```

| 결과 | 케이스 |
|------|--------|
| `LOCAL_SKILLS > 0`, 플러그인 없음 | Case A: 로컬 스킬만 |
| `LOCAL_SKILLS == 0`, 플러그인 있음 | Case B: 플러그인 기반 |
| 둘 다 있음 | Case C: 혼합 |
| 둘 다 없음 | Case D: 최소 (AGENTS.md만) |

## Step 2: 플러그인 해석 (Plugin Resolution)

플러그인 키마다 installPath를 찾는다:

```bash
resolve_plugin() {
  local plugin_key="$1"  # e.g. "sample-plugin@sample-marketplace"
  local manifest="$HOME/.claude/plugins/installed_plugins.json"

  python3 -c "
import json, os, sys
manifest = json.load(open('$manifest'))
entries = manifest.get('plugins', {}).get('$plugin_key', [])
pwd = os.getcwd()
local_path = user_path = None
for e in entries:
    scope = e.get('scope', '')
    if scope == 'local' and e.get('projectPath', '') == pwd:
        local_path = e['installPath']
    elif scope == 'user':
        user_path = e['installPath']
result = local_path or user_path
if result and os.path.isdir(result):
    print(result)
else:
    sys.exit(1)
" 2>/dev/null
}
```

매칭 규칙:
- `scope: "local"` -> `projectPath`가 `$PWD`와 정확히 일치 (우선)
- `scope: "user"` -> local 매칭 없을 때 적용
- `installPath` 디렉토리 미존재 -> 경고 후 건너뛰기 (플러그인 캐시 stale)
- 매칭 실패 -> 경고 후 건너뛰기

## Step 3: projection 재계산

Step 1-2에서 감지/해석한 결과를 `sync.sh all` 서브커맨드에 인자로 전달한다.

> Note: `sync.sh all`은 projection 산출물을 다시 계산한다. `.agents/`는 매번 삭제 후 재생성되고,
> 프로젝트-로컬 `.codex/config.toml`은 project/plugin source에서 생성한 managed MCP 블록만 갱신한다.
> 같은 이름의 기존 MCP entry는 교체하지만, managed marker 밖의 project-local MCP는 보존한다.
> user-scope MCP와 project/plugin MCP는 같은 `mcp-config` 호출에서 섞지 않는다.
> `sync.sh all`은 둘을 인자로 받을 수 있지만 내부에서 target별 `mcp-config` 호출로 분리한다.
> project/plugin MCP source가 더 이상 없으면 managed MCP 블록만 stale projection으로 보고 제거한다.
> 변경이 없어도 재실행해도 안전하다 (멱등).
> retired Codex hooks projection에서 남긴 `.codex/hooks.json`과
> `.codex/hooks.compatibility.json` 잔재는 초기화 단계에서 명시적으로 삭제한다.

### 계약 참고: user-scope `sync.sh` vs activation writer

이 스킬의 `sync.sh`는 target별 소유권을 분리한다.

- project/plugin target: `$PWD/.codex/config.toml`의 codex-sync managed MCP 블록을
  project/plugin source 기준으로 갱신한다. 같은 이름의 기존 MCP entry는 교체하지만,
  managed marker 밖의 project-local MCP는 보존한다. root inline table
  (`mcp_servers = { ... }`)은 안전 병합 범위 밖이므로 fail-fast한다.
- user target: `--user-mcp`가 명시된 경우에만 `~/.codex/config.toml`
  (또는 `--user-codex-config`)을 수정한다. user source에 들어 있는 MCP server name만 교체하고,
  다른 `[mcp_servers.*]` 및 non-MCP 설정은 보존한다. root inline table
  (`mcp_servers = { ... }`)은 안전 병합 범위 밖이므로 fail-fast한다. 현재 플랫폼에서
  활성화되는 Codex config template이 선언한 MCP server name과 충돌하면
  activation-owned leaf를 덮지 않도록 fail-fast한다.
- 두 target은 같은 `mcp-config` 호출에서 섞지 않는다. project/plugin source와 `--user-mcp`를 함께 넘기면 fail-fast한다.
- project target write 전 `.codex`가 symlink 또는 non-directory이면 fail-fast한다.
- config write는 같은 디렉터리 tempfile + mode `0600` + atomic rename으로 수행한다.

반면 Home Manager activation이 관리하는 `~/.codex/config.toml`의 그 외 모든 키
(`model`, `approval_policy`, `[features]`, `[plugins.*]` 등)는 별개 계약이며, 이 스킬이
손대지 않는다. 두 경로를 혼동하지 않도록 계약을 아래와 같이 나란히 둔다.

| 축 | user-scope `sync.sh` (이 스킬) | activation writer `sync-codex-config.py` |
|----|-------------------------------|-------------------------------------------|
| 관리 대상 | `$PWD/.codex/config.toml` (project/plugin target). 옵션 `--user-mcp`가 주어지면 별도 호출로 `~/.codex/config.toml`의 source-provided MCP server names만. | `~/.codex/config.toml` (전역, Home Manager). `[mcp_servers.*]`를 포함한 모든 template-declared leaf 전체. |
| 진입점 | LLM이 이 SKILL 지시에 따라 수동 호출 | `home.activation.syncCodexConfig` (매 activation 시 자동) + `nrs` NO_CHANGES 분기에서 `repair_codex_config_drift_no_changes` (NO_CHANGES drift 자동 복원 follow-up) |
| 교체 범위 | project/plugin target은 managed MCP 블록 + 같은 이름의 기존 entry만 교체하고 root inline MCP table은 fail-fast. user target은 user source에 있는 MCP server names만 교체하고 나머지는 보존하되, template-owned MCP name 충돌과 root inline MCP table은 fail-fast. | template이 선언한 모든 leaf (재귀, leaf 단위). 그 외 top-level 키 + `[projects.*]` + template에 없는 `[mcp_servers.<이름>]` + 선언 테이블 안의 sibling leaf는 모두 preserve |
| 쓰기 방식 | atomic tempfile + rename, mode 0600 | atomic tempfile + `os.replace`, mode 0600 |
| malformed input 대응 | fail-fast before write, 기존 config 보존 | `<target>.bad-<ts>`로 quarantine 후 template에서 재생성 |
| 검증 축 | 없음 (운영자가 수동 확인) | `sync-codex-config.py check` + `verify-ai-compat.sh`의 `template ↔ live drift 검증` 섹션 (writer와 `_walk_template_leaves` 공유) |

두 계약은 축이 다르다: activation writer가 `~/.codex/config.toml`의 base state
(repo-managed leaf 전체)를 유지하고, user-scope `sync.sh`는 명시적으로 전달된
user MCP server names만 덮어쓴다. Home Manager template-owned MCP name과 같은 이름을
user source에 넣으면 `sync.sh`가 fail-fast한다.

### 인자 구성

Step 1-2의 결과를 바탕으로 `sync.sh all` 인자를 구성한다:

```bash
SYNC_SH="<SKILL.md가 위치한 디렉토리>/references/sync.sh"

# 기본 인자
ARGS=()

# 로컬 스킬이 있으면 (Case A, C)
if [ -d ".claude/skills" ]; then
  ARGS+=(--local-skills-dir=.claude/skills)
fi

# 각 플러그인마다 (Case B, C)
# INSTALL_PATH: Step 2에서 해석한 installPath
# PLUGIN_NAME: plugin-key에서 @ 앞부분 (e.g. "sample-plugin")
ARGS+=(--plugin-install-path="$INSTALL_PATH:$PLUGIN_NAME")

# user-scope MCP는 명시적으로 요청받은 경우에만 함께 투영한다 (선택, 별도 target).
# 빠른 참조의 "MCP 섹션 가드 예시"와 동일한 source 파일 존재 가드 정책 적용.
if [ "${SYNC_USER_MCP:-0}" = "1" ] && [ -f "$HOME/.claude/mcp.json" ]; then
  ARGS+=(--user-mcp="$HOME/.claude/mcp.json")
fi

# 프로젝트에 CLAUDE.md가 없고, 플러그인이 CLAUDE.md를 제공하는 경우
if [ ! -e "CLAUDE.md" ] && [ -f "$INSTALL_PATH/CLAUDE.md" ]; then
  ARGS+=(--plugin-claude-md="$INSTALL_PATH/CLAUDE.md")
fi
```

### 실행

```bash
bash "$SYNC_SH" all "$PWD" "${ARGS[@]}"
```

진행상황이 stderr로 출력된다:
 ```text
=== syncing-codex-harness: Full Sync ===
 [1/7] Initialized .agents/ and .codex/
 [2/7] AGENTS.md: symlinked|copied|skipped
 [3/7] Local skills: N
 [4/7] Plugin skills: N, Agents: N
 [5/7] Rules -> AGENTS.override.md: N
 [6/7] MCP config updated (project)|cleared (project)|updated (user)|MCP config: no sources found
 [6b/7] MCP config updated (user)   # project target과 user target이 모두 갱신될 때만
 [7/7] Trust: trusted|already-trusted|skipped
=== Sync complete ===
```

### Codex 산출물의 git 추적

`.agents/`(스킬 심링크 트리), `AGENTS.md`, `AGENTS.override.md`는 Codex가 자동 발견하려면 프로젝트에 존재해야 하므로 커밋하는 것이 기본 운영 방식이다. 반면 `.codex/`는 프로젝트 MCP 설정(`config.toml`)을 담고 `mcp-config`가 `.mcp.json`의 env 시크릿을 평문 기록할 수 있어 글로벌 gitignore에서 계속 무시한다. 특정 산출물의 추적 여부를 바꾸려면 프로젝트 `.gitignore`에서 조정한다.

### User-scope MCP 투영 (Claude -> Codex)

`mcp-config`는 프로젝트 스코프 외에 user-scope 변환도 지원한다.

```bash
# ~/.claude/mcp.json -> ~/.codex/config.toml
if [ -f "$HOME/.claude/mcp.json" ]; then
  bash "$SYNC_SH" mcp-config "$PWD" \
    --user-mcp="$HOME/.claude/mcp.json"
fi

# target 경로를 명시적으로 지정할 수도 있음
if [ -f "$HOME/.claude/mcp.json" ]; then
  bash "$SYNC_SH" mcp-config "$PWD" \
    --user-mcp="$HOME/.claude/mcp.json" \
    --user-codex-config="$HOME/.codex/config.toml"
fi
```

> source 파일 존재 가드 정책의 단일 진실 원천은 위 "빠른 참조 > MCP 섹션 가드 예시"다. 두 예시 모두 같은 `if [ -f ]; then ... fi` 패턴을 따른다.

포맷 호환:
- Claude user-scope 형식: `{"mcpServers": {...}}`
- 레거시 형식: `{ "server-name": {...} }`

### 개별 서브커맨드 (필요시)

`all` 대신 개별 단계를 실행할 수도 있다:

| 서브커맨드 | 용도 |
|-----------|------|
| `init` | `.agents/`, `.codex/` 초기화 |
| `project-skills` | 로컬 스킬 프로젝션 |
| `plugin-skills` | 플러그인 스킬 프로젝션 |
| `agents` | 에이전트 파일 복사 |
| `agents-md` | AGENTS.md 생성 (심링크/복사) |
| `agents-override` | AGENTS.override.md 생성 (마커 기반) |
| `mcp-config` | 프로젝트/유저 대상 config.toml MCP 섹션 생성 |
| `trust-project` | Codex 전역 config에 project trust 추가/수리 (`all --trust-project`의 단일 단계) |

상세 사용법은 `sync.sh` 상단 Usage 참조.

## Edge Cases

| 상황 | 처리 |
|------|------|
| CLAUDE.md 없음 + 플러그인 CLAUDE.md 있음 | 플러그인 CLAUDE.md를 AGENTS.md로 복사 |
| CLAUDE.md 없음 + 플러그인 없음 | AGENTS.md 건너뛰기, 경고 |
| 스킬/플러그인 없음 | AGENTS.md만 생성, 경고 |
| 플러그인 캐시 경로 미존재 | 경고 후 건너뛰기 |
| 스킬 이름 충돌 (로컬 vs 플러그인) | 플러그인 스킬에 `{plugin-name}--` 접두사 |
| AGENTS.override.md 사용자 커스텀 보존 | 마커 외부 내용 유지 |
| `.codex/config.toml` 기존 설정 보존 | Step 3 "계약 참고: user-scope `sync.sh` vs activation writer" 표를 단일 진실 원천으로 참조. project/plugin target은 managed MCP 블록과 같은 이름의 entry만 교체, user target은 source-provided MCP server names만 교체. |
| `~/.claude/mcp.json` 형식 차이 | `mcpServers` 래퍼 유무 모두 허용 |
| Worktree 경로 | `$PWD`로 매칭 |

## 트러블슈팅

- `installPath` 해석 실패 시 플러그인 캐시 경로 존재 여부를 먼저 확인한다.
- 동기화 후 스킬이 안 보이면 `.agents/skills/<name>`이 디렉토리 심링크인지 확인한다.
- `chrome-devtools-mcp` 사용 시 동일 탭을 다른 도구(예: Claude in Chrome)와 동시 제어하지 않는다.

## 참조 문서

- `references/sync.sh` — 기계적 프로젝션 셸 스크립트
- `references/mcp-conversion.md` — MCP JSON->TOML 변환 가이드
- `references/agents-override-template.md` — AGENTS.override.md 템플릿
- `references/codex-structure.md` — Codex 프로젝트 구조 레퍼런스
