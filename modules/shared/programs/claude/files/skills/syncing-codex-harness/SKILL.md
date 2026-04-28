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
| 로컬 스킬만 | `bash "$SYNC_SH" project-skills "$PWD" .claude/skills` |
| MCP 섹션만 | `bash "$SYNC_SH" mcp-config "$PWD"` |
| User-scope MCP 투영 | `bash "$SYNC_SH" mcp-config "$PWD" --user-mcp="$HOME/.claude/mcp.json"` |
| .gitignore 점검 | `bash "$SYNC_SH" gitignore-check "$PWD"` |

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

## Step 3: 전체 재생성 (Full Regeneration)

Step 1-2에서 감지/해석한 결과를 `sync.sh all` 서브커맨드에 인자로 전달한다.

> Note: `sync.sh all`은 항상 전체 재생성을 수행한다. `.agents/`는 매번 삭제 후 재생성되고,
> 프로젝트-로컬 `.codex/config.toml`은 `[mcp_servers.*]` 섹션만 교체된다 (사용자 설정 보존).
> 변경이 없어도 재실행해도 안전하다 (멱등).
> retired Codex hooks projection에서 남긴 `.codex/hooks.json`과
> `.codex/hooks.compatibility.json` 잔재는 초기화 단계에서 명시적으로 삭제한다.

### 계약 참고: user-scope `sync.sh` vs activation writer

이 스킬의 `sync.sh`는 기본적으로 **repo-local `$PWD/.codex/config.toml`**의
`[mcp_servers.*]` 섹션만 LLM 요청에 따라 교체/보존하는 멱등 runner이다. 또한
`--user-mcp`가 지정되면 예외적으로 **`~/.codex/config.toml`의 `[mcp_servers.*]` 섹션만**
함께 교체한다 (`references/sync.sh`의 mcp-config target 참조). 두 경우 모두
`[mcp_servers.*]` 외의 설정은 건드리지 않는다.

반면 Home Manager activation이 관리하는 `~/.codex/config.toml`의 **그 외 모든 키**
(`model`, `approval_policy`, `[features]`, `[plugins.*]` 등)는 **별개 계약**이며, 이 스킬이
손대지 않는다. 두 경로를 혼동하지 않도록 계약을 아래와 같이 나란히 둔다.

| 축 | user-scope `sync.sh` (이 스킬) | activation writer `sync-codex-config.py` |
|----|-------------------------------|-------------------------------------------|
| 관리 대상 | `$PWD/.codex/config.toml` (프로젝트 로컬, 항상). 옵션 `--user-mcp`가 주어지면 `~/.codex/config.toml`도 포함하지만 **`[mcp_servers.*]` 섹션만**. | `~/.codex/config.toml` (전역, Home Manager). `[mcp_servers.*]`를 포함한 모든 template-declared leaf 전체. |
| 진입점 | LLM이 이 SKILL 지시에 따라 수동 호출 | `home.activation.syncCodexConfig` (매 activation 시 자동) + `nrs` NO_CHANGES 분기에서 `repair_codex_config_drift_no_changes` (NO_CHANGES drift 자동 복원 follow-up) |
| 교체 범위 | `[mcp_servers.*]` 섹션만 (그 외 사용자 설정 완전 보존) | template이 선언한 모든 leaf (재귀, leaf 단위). 그 외 top-level 키 + `[projects.*]` + template에 없는 `[mcp_servers.<이름>]` + 선언 테이블 안의 sibling leaf는 모두 preserve |
| 쓰기 방식 | 전체 재생성 (idempotent) | atomic tempfile + `os.replace`, mode 0600 |
| malformed input 대응 | 경고 후 넘어감 | `<target>.bad-<ts>`로 quarantine 후 template에서 재생성 |
| 검증 축 | 없음 (운영자가 수동 확인) | `sync-codex-config.py check` + `verify-ai-compat.sh`의 `template ↔ live drift 검증` 섹션 (writer와 `_walk_template_leaves` 공유) |

두 계약은 축이 다르다: activation writer가 `~/.codex/config.toml`의 base state
(repo-managed leaf 전체)를 유지하고, user-scope `sync.sh`는 `$PWD/.codex/config.toml`
전체를 소유하며 `--user-mcp` 옵션이 있을 때만 `~/.codex/config.toml`의
`[mcp_servers.*]` 섹션에도 한정적으로 MCP 항목을 덧씌운다.

### 인자 구성

Step 1-2의 결과를 바탕으로 `sync.sh all` 인자를 구성한다:

```bash
SYNC_SH="<SKILL.md가 위치한 디렉토리>/references/sync.sh"

# 기본 인자
ARGS=()

# 로컬 스킬이 있으면 (Case A, C)
[ -d ".claude/skills" ] && ARGS+=(--local-skills-dir=.claude/skills)

# 각 플러그인마다 (Case B, C)
# INSTALL_PATH: Step 2에서 해석한 installPath
# PLUGIN_NAME: plugin-key에서 @ 앞부분 (e.g. "sample-plugin")
ARGS+=(--plugin-install-path="$INSTALL_PATH:$PLUGIN_NAME")

# user-scope MCP까지 함께 투영하고 싶을 때 (선택)
ARGS+=(--user-mcp="$HOME/.claude/mcp.json")

# 프로젝트에 CLAUDE.md가 없고, 플러그인이 CLAUDE.md를 제공하는 경우
[ ! -e "CLAUDE.md" ] && [ -f "$INSTALL_PATH/CLAUDE.md" ] && \
  ARGS+=(--plugin-claude-md="$INSTALL_PATH/CLAUDE.md")
```

### 실행

```bash
bash "$SYNC_SH" all "$PWD" "${ARGS[@]}"
```

진행상황이 stderr로 출력된다:
```text
=== syncing-codex-harness: Full Sync ===
 [1/8] Initialized .agents/ and .codex/
 [2/8] AGENTS.md: symlinked|copied|skipped
 [3/8] Local skills: N
 [4/8] Plugin skills: N, Agents: N
 [5/8] Rules -> AGENTS.override.md: N
 [6/8] MCP config updated|no sources found
 [7/8] Trust: trusted|already-trusted|skipped
 [8/8] .gitignore OK|Missing .gitignore entries: ...
=== Sync complete ===
```

### .gitignore 누락 처리

`.agents/`와 `.codex/`는 글로벌 gitignore에서 관리된다.
`AGENTS.md`와 `AGENTS.override.md`가 누락으로 보고되면 사용자에게 프로젝트 `.gitignore`에 추가를 제안한다.
**자동으로 수정하지 않는다.**

### User-scope MCP 투영 (Claude -> Codex)

`mcp-config`는 프로젝트 스코프 외에 user-scope 변환도 지원한다.

```bash
# ~/.claude/mcp.json -> ~/.codex/config.toml
bash "$SYNC_SH" mcp-config "$PWD" \
  --user-mcp="$HOME/.claude/mcp.json"

# target 경로를 명시적으로 지정할 수도 있음
bash "$SYNC_SH" mcp-config "$PWD" \
  --user-mcp="$HOME/.claude/mcp.json" \
  --user-codex-config="$HOME/.codex/config.toml"
```

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
| `gitignore-check` | .gitignore 누락 확인 |

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
| `.codex/config.toml` 기존 설정 보존 | user-scope `$PWD/.codex/config.toml`의 `[mcp_servers.*]` 섹션만 교체 (그 외 사용자 설정 완전 보존). `--user-mcp` 옵션이 주어지면 `~/.codex/config.toml`의 `[mcp_servers.*]` 섹션에도 같은 규칙으로 반영하되 그 외 키는 건드리지 않음. `~/.codex/config.toml`의 `[mcp_servers.*]` 외 영역(`model`/`approval_policy`/`[features]`/`[plugins.*]` 등)은 activation writer가 별도 계약으로 관리하므로 이 스킬이 손대지 않음 (Step 3 "계약 참고" 참조). |
| `~/.claude/mcp.json` 형식 차이 | `mcpServers` 래퍼 유무 모두 허용 |
| Worktree 경로 | `$PWD`로 매칭 |

## 트러블슈팅

- `installPath` 해석 실패 시 플러그인 캐시 경로 존재 여부를 먼저 확인한다.
- 동기화 후 스킬이 안 보이면 `.agents/skills/<name>`이 디렉토리 심링크인지 확인한다.
- `.gitignore` 경고는 자동수정하지 않고 누락 항목을 수동 반영한다.
- `chrome-devtools-mcp` 사용 시 동일 탭을 다른 도구(예: Claude in Chrome)와 동시 제어하지 않는다.

## 참조 문서

- `references/sync.sh` — 기계적 프로젝션 셸 스크립트
- `references/mcp-conversion.md` — MCP JSON->TOML 변환 가이드
- `references/agents-override-template.md` — AGENTS.override.md 템플릿
- `references/codex-structure.md` — Codex 프로젝트 구조 레퍼런스
