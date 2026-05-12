#!/usr/bin/env bash
# check-skill-noise.sh — Agent Skill markdown LLM 노이즈 syntax 잔존 검증.
#
# 검증 대상 (PR #732 정책):
# - bold (`**X**`) 잔존: 0 건이어야 함 (코드 블록 / inline code 외).
# - excessive empty lines: 0 건이어야 함 (코드 블록 외). 정의는 "3+ consecutive newlines" (`\n{3,}`) —
#   markdown paragraph break (`\n\n`, 2 consecutive newlines) 는 보존하고, 그 이상은 정규화.
#
# 보존 대상 (변경 없음):
# - 코드 블록 (` ``` ... ``` `) 안 모든 syntax.
# - inline code (`` `X` ``) 안 모든 syntax.
# - HTML 태그, HTML comment, italic, strikethrough, emoji 등 본 검증 외.
#
# 회귀 차단 시스템 (lefthook hook / CI step) 통합은 별도 follow-up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="$REPO_ROOT/modules/shared/programs/claude/files/skills"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "[FAIL] Skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

python3 - "$SKILLS_DIR" <<'PY'
import re
import sys
from pathlib import Path

base = Path(sys.argv[1])

def tokenize_fences(text):
    # CommonMark fenced code block: opening fence 가 있으면 같은 character + 같거나 더 긴 length 의
    # closing fence 만 닫는다. 다른 fence 문자 (예: ``` 안 ~~~ 또는 ~~~ 안 ```) 는 content 로 취급.
    # 단일 open fence 상태만 유지 — nested fence 가정 금지.
    spans = []
    lines = text.split('\n')
    line_starts = [0]
    for line in lines[:-1]:
        line_starts.append(line_starts[-1] + len(line) + 1)
    open_fence = None  # (char, length, start_pos) 또는 None
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if indent >= 4:
            continue
        m = re.match(r'^(`{3,}|~{3,})', stripped)
        if not m:
            continue
        fence_str = m.group(1)
        char = fence_str[0]
        length = len(fence_str)
        after = stripped[length:]
        if open_fence is not None:
            top_char, top_len, top_start = open_fence
            if char == top_char and length >= top_len and after.strip() == '':
                end_pos = line_starts[i] + len(line)
                spans.append((top_start, end_pos))
                open_fence = None
            # else: content 줄로 간주 (다른 fence 문자거나 closing 매칭 실패)
            continue
        # 열린 fence 가 없을 때만 새 opening fence 인식
        open_fence = (char, length, line_starts[i])
    if open_fence is not None:
        char, length, start = open_fence
        spans.append((start, len(text)))
    return sorted(spans)


def tokenize_inline_code(text, fence_spans):
    def in_fence(pos):
        return any(s <= pos < e for s, e in fence_spans)
    spans = []
    runs = list(re.finditer(r'`+', text))
    used = [False] * len(runs)
    for i, m in enumerate(runs):
        if used[i] or in_fence(m.start()):
            continue
        run_len = len(m.group())
        for j in range(i + 1, len(runs)):
            if used[j]:
                continue
            m2 = runs[j]
            if in_fence(m2.start()) or len(m2.group()) != run_len:
                continue
            between = text[m.end():m2.start()]
            if '\n\n' in between:
                continue
            spans.append((m.start(), m2.end()))
            used[i] = True
            used[j] = True
            break
    return sorted(spans)


def protected_spans(text):
    fence = tokenize_fences(text)
    inline = tokenize_inline_code(text, fence)
    merged = sorted(fence + inline)
    out = []
    for s, e in merged:
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def is_contained(start, end, spans):
    for s, e in spans:
        if s <= start and end <= e:
            return True
    return False


def count_bold_outside(text):
    spans = protected_spans(text)
    count = 0
    locations = []
    for m in re.finditer(r'\*\*[^*\n]+\*\*', text):
        if not is_contained(m.start(), m.end(), spans):
            count += 1
            lineno = text[:m.start()].count('\n') + 1
            locations.append((lineno, m.group()[:60]))
    return count, locations


def count_excessive_empty_outside(text):
    spans = protected_spans(text)
    count = 0
    locations = []
    # 3+ consecutive newlines (= 2+ empty lines 이상). markdown paragraph break (\n\n, 2 newlines) 는 보존.
    for m in re.finditer(r'\n{3,}', text):
        if not any(s <= m.start() < e for s, e in spans):
            count += 1
            lineno = text[:m.start()].count('\n') + 1
            locations.append((lineno, len(m.group())))
    return count, locations


total_bold = 0
total_empty = 0
fail = False
for f in sorted(base.rglob('*.md')):
    text = f.read_text()
    bc, blocs = count_bold_outside(text)
    ec, elocs = count_excessive_empty_outside(text)
    if bc > 0 or ec > 0:
        fail = True
        rel = f.relative_to(base)
        if bc > 0:
            print(f"[FAIL] {rel}: bold {bc} 건 잔존")
            for ln, ctx in blocs[:5]:
                print(f"        L{ln}: {ctx!r}")
        if ec > 0:
            print(f"[FAIL] {rel}: excessive empty lines {ec} 건 잔존")
            for ln, nl in elocs[:5]:
                print(f"        L{ln}: {nl} consecutive newlines")
        total_bold += bc
        total_empty += ec

if fail:
    print(f"\n[FAIL] TOTAL bold={total_bold}, excessive_empty={total_empty}")
    sys.exit(1)

print("[PASS] bold + excessive empty lines 잔존 0 건 (보호 컨텍스트 외)")
PY
