#!/usr/bin/env bash
# repo-local `.claude/skills/` → `.agents/skills/` Codex 스킬 투영.
# 호출자: home.activation.createCodexProjectSymlinks (modules/shared/programs/codex/default.nix).
# 이전 시도(5ef4e67)의 sync-codex-from-claude.sh 로직을 Nix activation으로 이식한 본체이며,
# 동작 fixture(tests/suites/codex-activation-static.sh)로 검증하려고 Nix 문자열에서 분리했다.
#
# 사용: DRY_RUN_CMD=<빈 값|echo> project-codex-skills.sh <project-dir> [git]
# - git: activation은 git의 store 절대경로를 넘긴다. 생략하면 PATH의 git을 쓴다. 찾지 못하면
#   git 추적 실디렉토리 방어가 판정을 못 하므로 아무것도 바꾸지 않고 실패한다.
# - DRY_RUN_CMD: Home Manager activation이 항상 export한다 (live면 빈 값, dry-run이면 echo —
#   변경 명령만 출력되고 실행되지 않는다). 변수가 아예 없으면 activation 밖 호출이라 dry-run
#   여부를 알 수 없으므로 아무것도 바꾸지 않고 실패한다. activation 인라인 원본이 set -u로
#   멈추던 것과 같은 실패 모드다. 수동 실행은 `DRY_RUN_CMD='' bash ...`처럼 값을 명시한다.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: DRY_RUN_CMD=<""|echo> %s <project-dir> [git]\n' "$0" >&2
  exit 2
fi
if [ -z "${DRY_RUN_CMD+set}" ]; then
  echo "Refusing to project Codex skills: DRY_RUN_CMD is not set (set DRY_RUN_CMD='' for a live run or DRY_RUN_CMD=echo for a dry run)" >&2
  exit 2
fi

PROJECT_DIR="$1"
GIT_BIN="${2:-git}"
if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
  echo "Refusing to project Codex skills: git not found ($GIT_BIN), so git-tracked directories cannot be protected" >&2
  exit 1
fi
SOURCE_SKILLS="$PROJECT_DIR/.claude/skills"
TARGET_SKILLS="$PROJECT_DIR/.agents/skills"

if [ -L "$PROJECT_DIR/.agents" ]; then
  echo "Refusing to project Codex skills through .agents symlink: $PROJECT_DIR/.agents" >&2
  exit 1
fi
if [ -e "$PROJECT_DIR/.agents" ] && [ ! -d "$PROJECT_DIR/.agents" ]; then
  echo "Refusing to project Codex skills because .agents is not a directory: $PROJECT_DIR/.agents" >&2
  exit 1
fi
if [ -L "$TARGET_SKILLS" ]; then
  echo "Refusing to project Codex skills through .agents/skills symlink: $TARGET_SKILLS" >&2
  exit 1
fi
if [ -e "$TARGET_SKILLS" ] && [ ! -d "$TARGET_SKILLS" ]; then
  echo "Refusing to project Codex skills because .agents/skills is not a directory: $TARGET_SKILLS" >&2
  exit 1
fi

# ── AGENTS.md → CLAUDE.md 심링크 ──
if [ ! -L "$PROJECT_DIR/AGENTS.md" ] || [ "$(readlink "$PROJECT_DIR/AGENTS.md")" != "CLAUDE.md" ]; then
  $DRY_RUN_CMD ln -sfn "CLAUDE.md" "$PROJECT_DIR/AGENTS.md"
fi

# ── .agents/skills/ 디렉토리 생성 ──
$DRY_RUN_CMD mkdir -p "$TARGET_SKILLS"

# ── 스킬 투영 (디렉토리 심링크) ──
# Codex CLI는 디렉토리 심링크를 따라감 (PR #8801)
# 파일 심링크는 무시하므로 반드시 디렉토리 단위로 심링크
# Claude Code 전용 스킬은 Codex 프로젝션에서 제외 (자기 참조 방지, #212)
# NOTE: 아래 변수는 repo-local `.claude/skills/` → `.agents/skills/` 투영 축 전용이다.
# shared global `~/.codex/skills/` exposure 정책(exposedCodexSkills / intentionallyNotExposed)과
# 별개의 축이며, SoT는 default.nix의 let 블록이다 (#486).
CODEX_EXCLUDE_SKILLS="using-codex-exec"
# 관리 링크 자리에 남은 실디렉토리·파일을 보존할 때 경고에 붙이는 조치 (#1455).
KEEP_ACTION="review its contents, move or delete it, then rerun nrs"
for source_skill_dir in "$SOURCE_SKILLS"/*/; do
  [ -d "$source_skill_dir" ] || continue
  [ -f "$source_skill_dir/SKILL.md" ] || continue

  skill_name="$(basename "$source_skill_dir")"

  # Claude Code 전용 스킬 제외
  case " $CODEX_EXCLUDE_SKILLS " in
    *" $skill_name "*) continue ;;
  esac
  target_link="$TARGET_SKILLS/$skill_name"
  expected="../../.claude/skills/$skill_name"

  # 이미 올바른 심링크면 스킵
  if [ -L "$target_link" ] && [ "$(readlink "$target_link")" = "$expected" ]; then
    continue
  fi

  # 관리 링크 자리의 실디렉토리는 추적 여부와 관계없이 지우지 않는다 (#1455). 그 안을 만들던
  # 옛 파일 복사 투영(#38 이전)은 사라졌으므로, 남은 실디렉토리는 사용자 자료일 수 있다.
  if [ -d "$target_link" ] && [ ! -L "$target_link" ]; then
    # git이 추적하는 실디렉토리는 git pull 전에 nrs가 먼저 돈 경우다 (PR#38 사후 분석에서 도출).
    tracked_rc=0
    "$GIT_BIN" -C "$PROJECT_DIR" ls-files --error-unmatch "$target_link/SKILL.md" >/dev/null 2>&1 \
      || tracked_rc=$?
    if [ "$tracked_rc" -eq 0 ]; then
      echo "Skipping .agents/skills/$skill_name: git-tracked directory (run 'git pull' first)"
      continue
    fi
    # --error-unmatch는 미추적이면 1로 끝난다. 그 밖의 실패(저장소가 아님 등)는 추적 여부를
    # 모른다는 뜻이므로 미추적으로 간주하지 않고 보존한다.
    if [ "$tracked_rc" -ne 1 ]; then
      echo "Warning: keeping .agents/skills/$skill_name: cannot tell whether it is git-tracked (git ls-files exit $tracked_rc); $KEEP_ACTION" >&2
      continue
    fi
    # SKILL.md가 없거나 미추적이면 디렉토리 전체가 미추적이든 다른 파일은 추적이든 보존한다. 고아 정리의
    # 보존 경고와 같이 rc는 바꾸지 않고, 정리는 사람이 판단한다 (verify-ai-compat.sh도 실패로 보고한다).
    echo "Warning: keeping .agents/skills/$skill_name: real directory in place of the managed projection link $expected (SKILL.md is missing or not git-tracked); $KEEP_ACTION" >&2
    continue
  fi
  if [ -e "$target_link" ] && [ ! -L "$target_link" ]; then
    echo "Warning: keeping .agents/skills/$skill_name: file in place of the managed projection link $expected; $KEEP_ACTION" >&2
    continue
  fi

  # 누락이면 만들고, 다른 대상을 가리키는 심링크면 그 링크만 바꾼다 (링크 대상은 건드리지 않는다).
  # 실디렉토리·파일은 위에서 모두 건너뛰므로 rm -rf를 쓰지 않는다 — rm -f는 디렉토리를 지우지
  # 못하고 실패하므로, 위 분기가 깨져도 사용자 자료를 지우는 대신 activation이 멈춘다.
  $DRY_RUN_CMD rm -f "$target_link"
  $DRY_RUN_CMD ln -sfn "$expected" "$target_link"
done

# ── 고아 심링크 정리 ──
# 이 스크립트가 소유를 입증할 수 있는 것은 위 투영 루프가 만드는 관리 링크
# (`../../.claude/skills/<name>` 상대 심링크)뿐이다. 원본이 사라진 관리 링크만 제거하고,
# 실디렉토리(추적 파일·미추적 초안)와 다른 대상을 가리키는 링크는 지우지 않는다 (#1366).
# 절대경로 target이면서 SKILL.md에 접근 가능한 링크는 scripts/ai/verify-ai-compat.sh가
# 허용하는 플러그인 스킬 링크와 같은 기준이라 조용히 보존한다. 그 밖의 항목은 보존하되
# 경고만 한다 — 검증기는 그 항목을 계속 고아 투영으로 보고하므로 정리는 사람이 판단한다.
if [ -d "$TARGET_SKILLS" ]; then
  for entry in "$TARGET_SKILLS"/*; do
    [ -L "$entry" ] || [ -d "$entry" ] || continue
    skill_name="$(basename "$entry")"
    if [ -d "$SOURCE_SKILLS/$skill_name" ]; then
      continue
    fi
    if [ ! -L "$entry" ]; then
      echo "Warning: keeping .agents/skills/$skill_name: real directory without .claude/skills/$skill_name (not a managed projection link)" >&2
      continue
    fi
    link_target="$(readlink "$entry")"
    if [ "$link_target" = "../../.claude/skills/$skill_name" ]; then
      echo "Removing orphan projected skill: .agents/skills/$skill_name"
      $DRY_RUN_CMD rm -f "$entry"
      continue
    fi
    if [[ "$link_target" = /* ]] && [ -f "$entry/SKILL.md" ]; then
      continue
    fi
    echo "Warning: keeping .agents/skills/$skill_name: symlink target '$link_target' is not the managed projection ../../.claude/skills/$skill_name" >&2
  done
fi
