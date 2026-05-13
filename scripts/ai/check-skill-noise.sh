#!/usr/bin/env bash
# check-skill-noise.sh — Agent Skill markdown LLM 노이즈 syntax 잔존 검증.
#
# 검증 대상 (PR #732 정책):
# - bold (`**X**`) 잔존: 0 건이어야 함 (코드 블록 / inline code 외).
# - excessive empty lines: 0 건이어야 함 (코드 블록 외). 정의는 "3+ consecutive newlines" (`\n{3,}`) —
#   markdown paragraph break (`\n\n`, 2 consecutive newlines) 는 보존하고, 그 이상은 정규화.
#   파일 읽기는 Python `Path.read_text(encoding="utf-8-sig")` 의 universal newlines 동작에 의존하므로
#   `\r\n` 입력도 `\n` 으로 정규화되어 동일 regex 가 CRLF 파일을 정상 검출한다.
#
# 보존 대상 (변경 없음):
# - 코드 블록 (` ``` ... ``` `) 안 모든 syntax.
# - inline code (`` `X` ``) 안 모든 syntax. CommonMark escaped backtick (`` \` ``) 은 inline code
#   delimiter 가 아닌 literal 로 인식한다.
# - HTML 태그, HTML comment, italic, strikethrough, emoji 등 본 검증 외.
#
# 회귀 차단:
# - lefthook pre-commit `skill-noise-check` 항목으로 자동 통합 완료.
# - CI step (GitHub Actions) 통합은 `.github/workflows/` 부재로 별도 follow-up.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# 첫 positional arg 가 SKILLS_DIR override (PoC / 테스트 전용). 미지정 시 canonical repo 경로.
# pre-commit hook 은 인자 없이 호출하여 ambient env 와 무관하게 canonical corpus 만 검사한다.
SKILLS_DIR="${1:-$REPO_ROOT/modules/shared/programs/claude/files/skills}"

if [ ! -d "$SKILLS_DIR" ]; then
  echo "[FAIL] Skills directory not found: $SKILLS_DIR" >&2
  exit 1
fi

python3 - "$SKILLS_DIR" <<'PY'
import bisect
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


def _in_span(pos, sorted_spans, starts):
    # sorted_spans 는 start 기준 정렬된 (start, end) 리스트. starts 는 (start, ...) 의 분리 캐시.
    # bisect_right - 1 로 pos 이하의 가장 큰 start 를 찾고, end 와 비교한다.
    if not sorted_spans:
        return False
    idx = bisect.bisect_right(starts, pos) - 1
    if idx < 0:
        return False
    s, e = sorted_spans[idx]
    return s <= pos < e


def tokenize_inline_code(text, fence_spans):
    # 같은 길이의 backtick run 두 개로 둘러싸인 inline code span을 paired matching.
    # CommonMark: 같은 길이 backtick run delimiter, between text 에 두 개 이상의 연속 newline (`\n\n`)
    # 있으면 inline code 미성립.
    # Escaped backtick: opening delimiter 후보일 때만 escape literal 처리 (backslash 홀수 개면 skip).
    # closing delimiter 후보 (open queue 에 같은 길이 entry 존재) 일 때는 escape 검사하지 않는다.
    # CommonMark code span 내부에서는 backslash escape 가 동작하지 않기 때문이다 (Example 338).
    # Fenced code block 안 backtick 은 fence_spans 로 미리 걸러진다.
    fence_starts = [s for s, e in fence_spans]
    spans = []
    open_runs = {}  # length -> [Match, ...] (FIFO queue per length)

    def is_escaped(pos):
        backslashes = 0
        i = pos - 1
        while i >= 0 and text[i] == '\\':
            backslashes += 1
            i -= 1
        return backslashes % 2 == 1

    for m in re.finditer(r'`+', text):
        start = m.start()
        if _in_span(start, fence_spans, fence_starts):
            continue
        run_len = len(m.group())
        queue = open_runs.get(run_len)
        if queue:
            # closing delimiter 후보 — escape 검사 안 함 (code span 내부 escape 미동작)
            m_open = queue.pop(0)
            between = text[m_open.end():start]
            if '\n\n' in between:
                # blank-line 을 사이에 둔 opener 는 만료한다. 그대로 큐에 두면 뒤쪽 문단의
                # 정상 backtick pair 가 늘 같은 만료 opener 와 매칭되어 inline code span 으로
                # 등록되지 않는다. 따라서 현재 run 은 새 opening delimiter 후보로 재평가한다.
                if not queue:
                    del open_runs[run_len]
                if not is_escaped(start):
                    open_runs.setdefault(run_len, []).append(m)
            else:
                spans.append((m_open.start(), m.end()))
                if not queue:
                    del open_runs[run_len]
        else:
            # opening delimiter 후보 — escape 검사
            if is_escaped(start):
                continue
            open_runs.setdefault(run_len, []).append(m)
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


def count_bold_outside(text):
    spans = protected_spans(text)
    starts = [s for s, e in spans]
    count = 0
    locations = []
    for m in re.finditer(r'\*\*[^*\n]+\*\*', text):
        # bold 매치 전체가 같은 span 안에 contained 되어야 protected.
        contained = False
        if spans:
            idx = bisect.bisect_right(starts, m.start()) - 1
            if idx >= 0:
                s, e = spans[idx]
                if s <= m.start() and m.end() <= e:
                    contained = True
        if not contained:
            count += 1
            lineno = text[:m.start()].count('\n') + 1
            locations.append((lineno, m.group()[:60]))
    return count, locations


def count_excessive_empty_outside(text):
    spans = protected_spans(text)
    starts = [s for s, e in spans]
    count = 0
    locations = []
    # 3+ consecutive newlines (= 2+ empty lines 이상). markdown paragraph break (\n\n) 는 보존.
    for m in re.finditer(r'\n{3,}', text):
        if not _in_span(m.start(), spans, starts):
            count += 1
            lineno = text[:m.start()].count('\n') + 1
            locations.append((lineno, len(m.group())))
    return count, locations


md_files = sorted(base.rglob('*.md'))
if not md_files:
    print(f"[FAIL] {base} 하위에 *.md 파일이 0 개 — skill projection 깨짐 또는 잘못된 SKILLS_DIR.", file=sys.stderr)
    sys.exit(1)

total_bold = 0
total_empty = 0
fail = False
for f in md_files:
    text = f.read_text(encoding="utf-8-sig")
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
