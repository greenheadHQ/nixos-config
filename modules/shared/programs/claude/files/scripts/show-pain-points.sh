#!/usr/bin/env bash
# Pain point 대시보드 HTML 생성 + 브라우저 열기
#
# 사용법: show-pain-points.sh [TEMPLATE_PATH]
# 환경변수:
#   PAIN_POINTS_FILE   — active JSONL 경로 (기본: ~/.claude/pain-points.jsonl)
#   PAIN_ARCHIVE_FILE  — archive JSONL 경로 (기본: ~/.claude/pain-points.archive.jsonl)

set -euo pipefail

PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"
ARCHIVE_FILE="${PAIN_ARCHIVE_FILE:-$HOME/.claude/pain-points.archive.jsonl}"
TEMPLATE="${1:-$HOME/.claude/skills/show-pains/references/template.html}"
OUTPUT="/tmp/pain-dashboard.html"
REASON_CACHE="$HOME/.claude/pain-reason-cache.json"

# 1) 데이터 존재 확인
if { [ ! -f "$PAIN_FILE" ] || [ ! -s "$PAIN_FILE" ]; } && \
   { [ ! -f "$ARCHIVE_FILE" ] || [ ! -s "$ARCHIVE_FILE" ]; }; then
  echo "pain point 데이터가 없습니다."
  echo "  active: $PAIN_FILE"
  echo "  archive: $ARCHIVE_FILE"
  exit 0
fi

# 2) JSONL → JSON 배열 병합
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
{
  [ -f "$PAIN_FILE" ] && [ -s "$PAIN_FILE" ] && cat "$PAIN_FILE" || true
  [ -f "$ARCHIVE_FILE" ] && [ -s "$ARCHIVE_FILE" ] && cat "$ARCHIVE_FILE" || true
# 불량 JSONL 행을 건너뛰고 유효한 레코드만 수집
# jq -Rc: 각 줄을 raw string으로 읽어 fromjson?로 파싱 (실패 시 skip)
# jq -s: 결과를 배열로 합침
} | jq -Rc 'fromjson?' 2>/dev/null | jq -s '.' > "$TMPDIR/data.json" 2>/dev/null || echo '[]' > "$TMPDIR/data.json"

# 3) context가 없는 레코드에 대해 transcript에서 context 보충 (fallback)
# hook에서 감지 시점 context를 이미 저장한 레코드는 skip.
# 기존 레코드(context 없음)에 대해 session_id로 transcript를 찾아 최근 4턴 추출.
python3 -c "
import json, sys, os, glob

data = json.load(open(sys.argv[1]))
claude_dir = os.path.expanduser('~/.claude')

for entry in data:
    # context가 이미 있고 비어있지 않으면 skip
    if entry.get('context') and len(entry['context']) > 0:
        continue

    # session_id로 transcript 찾기
    sid = entry.get('session_id', '')
    if not sid or sid == 'unknown':
        continue

    # transcript 검색: ~/.claude/projects/*/<session_id>.jsonl
    pattern = os.path.join(claude_dir, 'projects', '*', f'{sid}.jsonl')
    matches = glob.glob(pattern)
    if not matches:
        continue

    transcript_path = matches[0]
    entry['transcript_path'] = transcript_path

    # transcript에서 최근 user/assistant 턴 4개 추출
    try:
        lines = open(transcript_path).readlines()
        records = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                if rec.get('type') in ('user', 'assistant'):
                    content = ''
                    msg = rec.get('message', {})
                    if isinstance(msg.get('content'), str):
                        content = msg['content'][:300]
                    elif isinstance(msg.get('content'), list):
                        for block in msg['content']:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                content = block.get('text', '')[:300]
                                break
                    # 텍스트가 있는 턴만 수집 (tool_use만 있는 턴은 skip)
                    if content.strip():
                        records.append({'type': rec['type'], 'content': content})
            except (json.JSONDecodeError, KeyError):
                continue

        # 텍스트가 있는 최근 4턴 추출
        entry['context'] = records[-4:] if records else []
    except Exception:
        pass

json.dump(data, open(sys.argv[1], 'w'), ensure_ascii=False)
" "$TMPDIR/data.json" 2>/dev/null || true

# 4) LLM reason 요약 생성 (캐시 기반, context가 있는 레코드만)
# best-effort: 실패해도 대시보드 생성은 계속
(
  set +eu
  if ! command -v claude >/dev/null 2>&1; then exit 0; fi

  # 캐시 로드
  CACHE="{}"
  [ -f "$REASON_CACHE" ] && CACHE=$(cat "$REASON_CACHE")

  # context가 있고 캐시에 reason이 없는 레코드 수집
  NEEDS_REASON=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
cache = json.loads(sys.argv[2]) if sys.argv[2] != '{}' else {}
needs = []
for e in data:
    key = e.get('ts', '') + '|' + e.get('session_id', '')
    if key in cache:
        continue
    ctx = e.get('context', [])
    if not ctx:
        continue
    needs.append({
        'key': key,
        'description': e.get('description', ''),
        'user_note': e.get('user_note'),
        'context': ctx
    })
json.dump(needs[:10], sys.stdout, ensure_ascii=False)
" "$TMPDIR/data.json" "$CACHE" 2>/dev/null) || NEEDS_REASON="[]"

  NEED_COUNT=$(printf '%s' "$NEEDS_REASON" | jq 'length' 2>/dev/null) || NEED_COUNT=0

  if [ "${NEED_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "LLM reason 분석 중... (${NEED_COUNT}건)" >&2

    REASON_RESULT=$(printf '%s' "아래 pain point들의 context(대화 이력)를 분석하여, 사용자가 왜 불편/분노를 느꼈는지 한국어 한 줄(50자 이내)로 요약하라.

출력: JSON 객체. key는 각 항목의 key 값을 그대로 사용.
예시: {\"2026-03-29T10:00:00+00:00|aaa111\": \"요청과 다른 파일을 수정하여 재작업 필요\"}

항목:
${NEEDS_REASON}" | PAIN_COLLECTING=1 timeout 60 claude -p 2>/dev/null) || REASON_RESULT="{}"

    # JSON 추출 (code block 안에 있을 수 있음)
    EXTRACTED=$(printf '%s' "$REASON_RESULT" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', text, re.DOTALL)
if m:
    try:
        obj = json.loads(m.group())
        json.dump(obj, sys.stdout, ensure_ascii=False)
    except: print('{}')
else: print('{}')
" 2>/dev/null) || EXTRACTED="{}"

    # 캐시 병합
    if [ -n "$EXTRACTED" ] && [ "$EXTRACTED" != "{}" ]; then
      python3 -c "
import json, sys
cache = json.loads(sys.argv[1]) if sys.argv[1] != '{}' else {}
new = json.loads(sys.argv[2])
cache.update(new)
json.dump(cache, open(sys.argv[3], 'w'), ensure_ascii=False)
" "$CACHE" "$EXTRACTED" "$REASON_CACHE" 2>/dev/null || true
    fi
  fi

  # reason 캐시를 데이터에 병합
  if [ -f "$REASON_CACHE" ]; then
    python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
cache = json.load(open(sys.argv[2]))
for e in data:
    key = e.get('ts', '') + '|' + e.get('session_id', '')
    if key in cache:
        e['reason'] = cache[key]
json.dump(data, open(sys.argv[1], 'w'), ensure_ascii=False)
" "$TMPDIR/data.json" "$REASON_CACHE" 2>/dev/null || true
  fi
) || true

# 5) 템플릿에 데이터 주입
# XSS 방지: JSON 내 </script> → <\/script> 이스케이프
python3 -c "
import sys
template = open(sys.argv[1]).read()
data = open(sys.argv[2]).read()
safe_data = data.replace('</', r'<\/')
print(template.replace('__PAIN_DATA_JSON__', safe_data))
" "$TEMPLATE" "$TMPDIR/data.json" > "$OUTPUT"

# 6) 브라우저 열기
echo "대시보드: file://$OUTPUT"
if command -v open >/dev/null 2>&1; then
  open "$OUTPUT"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$OUTPUT"
else
  echo "브라우저를 수동으로 열어주세요: file://$OUTPUT"
fi
