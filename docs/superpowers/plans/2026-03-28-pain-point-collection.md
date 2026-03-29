# Pain Point Collection Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code 세션에서 사용자의 pain point를 자동/수동으로 수집하고, 세션 시작 시 Claude가 자동으로 읽어 행동을 조정하는 harness 구축

**Architecture:** Stop hook이 세션 종료 시 transcript를 분석하여 교정 키워드/reject/세션 메트릭을 감지, JSONL 파일에 기록. SessionStart hook이 최근 7일 항목을 additionalContext로 주입. /pain 스킬로 수동 태깅. 7일 이전 항목은 claude -p로 요약하여 feedback memory로 승격.

**Tech Stack:** Bash, jq, Claude Code hooks (Stop, SessionStart), Claude Code skills (SKILL.md), Nix (home.file mkOutOfStoreSymlink)

**Spec:** `docs/superpowers/specs/2026-03-28-pain-point-collection-design.md`

---

## File Structure

| Action | Path | 역할 |
|--------|------|------|
| Create | `modules/shared/programs/claude/files/skills/pain/SKILL.md` | /pain 수동 태깅 스킬 |
| Create | `modules/shared/programs/claude/files/hooks/collect-pain-points.sh` | Stop hook — 자동 수집 + 정제 |
| Create | `modules/shared/programs/claude/files/hooks/read-pain-points.sh` | SessionStart hook — pain point 읽기 |
| Modify | `modules/shared/programs/claude/files/settings.json` | hook 배열에 2개 항목 추가 |
| Modify | `modules/shared/programs/claude/default.nix` | symlink 3개 추가 (hooks 2 + skill 1) |

---

### Task 1: /pain 스킬 생성

**Files:**
- Create: `modules/shared/programs/claude/files/skills/pain/SKILL.md`

- [ ] **Step 1: 스킬 디렉토리 생성 + SKILL.md 작성**

```bash
mkdir -p modules/shared/programs/claude/files/skills/pain
```

`modules/shared/programs/claude/files/skills/pain/SKILL.md`:

```markdown
---
name: pain
description: |
  Pain point 수동 태깅. 세션 중 불편함을 느꼈을 때 기록.
  Trigger: '/pain', 'pain point 기록', '불편 기록', '페인 포인트'.
---

# Pain Point 수동 태깅

사용자가 세션 중 불편함을 느꼈을 때 `/pain <메모>`로 기록합니다.
기록된 pain point는 이후 세션에서 Claude가 자동으로 읽어 행동을 조정합니다.

## 실행 절차

ARGUMENTS의 전체 텍스트를 `user_note`로 사용합니다. ARGUMENTS가 비어있으면 사용자에게 무엇이 불편했는지 물어보세요.

Bash tool로 아래 명령을 실행하세요. `<USER_NOTE>` 부분을 ARGUMENTS 값으로 교체합니다:

\```bash
jq -nc \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  --arg repo "$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo unknown)" \
  --arg branch "$(git branch --show-current 2>/dev/null || echo unknown)" \
  --arg note "<USER_NOTE>" \
  '{
    ts: $ts,
    session_id: "manual",
    repo: $repo,
    branch: $branch,
    source: "manual",
    severity: "medium",
    signals: {},
    description: ("수동 태깅: " + $note),
    user_note: $note
  }' >> ~/.claude/pain-points.jsonl
\```

## 완료 후

"Pain point 기록 완료" 메시지를 간결하게 출력합니다. 기록한 내용을 되풀이하지 마세요.
```

- [ ] **Step 2: 커밋**

```bash
git add modules/shared/programs/claude/files/skills/pain/SKILL.md
git commit -m "feat(pain): /pain 수동 태깅 스킬 생성"
```

---

### Task 2: Transcript 형식 조사

collect-pain-points.sh를 작성하기 전에 실제 transcript JSONL의 구조를 확인해야 합니다.

**Files:**
- 없음 (조사만)

- [ ] **Step 1: 최근 transcript 파일 찾기**

```bash
find ~/.claude -name "*.jsonl" -path "*/conversations/*" -mtime -1 2>/dev/null | head -5
```

transcript 파일이 없으면 현재 세션의 경로를 확인:

```bash
ls -la ~/.claude/projects/*/conversations/ 2>/dev/null | tail -20
```

- [ ] **Step 2: User 메시지 구조 확인**

transcript 파일을 찾았으면 user 메시지의 정확한 type과 content 구조를 확인:

```bash
TRANSCRIPT=$(find ~/.claude -name "*.jsonl" -path "*/conversations/*" -mtime -1 2>/dev/null | head -1)
jq -Rrs 'split("\n") | map(select(length > 0) | fromjson?) | map(select(.type == "human"))[0]' "$TRANSCRIPT" 2>/dev/null | jq '.'
```

user 메시지의 `.type`이 `"human"`인지 다른 값인지 확인. `.message` 구조도 확인.

만약 `"human"`이 아닌 다른 type을 사용한다면 아래 Task 3의 코드에서 해당 type으로 수정 필요.

- [ ] **Step 3: Tool rejection 구조 확인**

사용자가 tool call을 deny했을 때 transcript에 어떻게 기록되는지 확인:

```bash
jq -Rrs 'split("\n") | map(select(length > 0) | fromjson?) | map(.type) | unique' "$TRANSCRIPT"
```

모든 type 목록을 확인한 후, tool_result 등에서 denial/rejection 관련 필드를 찾음:

```bash
jq -Rrs 'split("\n") | map(select(length > 0) | fromjson?) | map(select(.type == "tool_result"))[0]' "$TRANSCRIPT" 2>/dev/null | jq '.'
```

- [ ] **Step 4: 조사 결과를 Task 3 코드에 반영**

확인한 실제 필드명(.type 값, .message 구조, rejection 표현)을 Task 3의 jq 필터에 반영.
이 정보가 없으면 Task 3는 아래 기본 가정값으로 시작:
- user 메시지: `.type == "human"`, `.message` 는 string
- rejection: detection skip (향후 추가)

---

### Task 3: collect-pain-points.sh (Stop hook — 자동 수집)

**Files:**
- Create: `modules/shared/programs/claude/files/hooks/collect-pain-points.sh`

- [ ] **Step 1: 테스트용 mock transcript 생성 + 검증 명령 작성**

테스트 환경을 구성하고, 아직 존재하지 않는 스크립트를 호출하여 실패를 확인합니다.

```bash
TEST_DIR=$(mktemp -d)
MOCK_TRANSCRIPT="$TEST_DIR/transcript.jsonl"

# mock transcript: 교정 키워드 "아니" + ";;" 포함
cat > "$MOCK_TRANSCRIPT" << 'JSONL'
{"type":"user","message":"Nix 설정 파일을 수정해줘","timestamp":"2026-03-28T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"네, 수정하겠습니다."}]},"timestamp":"2026-03-28T10:01:00Z"}
{"type":"user","message":"아니 그 파일 말고 다른 거","timestamp":"2026-03-28T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"죄송합니다."}]},"timestamp":"2026-03-28T10:03:00Z"}
{"type":"user","message":";;","timestamp":"2026-03-28T10:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"다시 확인하겠습니다."}]},"timestamp":"2026-03-28T10:05:00Z"}
JSONL

echo '{"session_id":"test-123","transcript_path":"'"$MOCK_TRANSCRIPT"'"}' | \
  bash modules/shared/programs/claude/files/hooks/collect-pain-points.sh 2>&1; echo "EXIT: $?"
```

Expected: 스크립트가 존재하지 않으므로 `No such file` 에러.

- [ ] **Step 2: 실패 확인**

Run: 위의 명령 실행
Expected: FAIL — `No such file or directory`

- [ ] **Step 3: collect-pain-points.sh 구현**

`modules/shared/programs/claude/files/hooks/collect-pain-points.sh`:

```bash
#!/usr/bin/env bash
# Claude Code Stop Hook - Pain point 자동 수집
# stdin: JSON {session_id, transcript_path, agent_id}
# stdout: (없음 — pain-points.jsonl에 append)
#
# 교정 키워드 감지, tool reject 카운팅, 세션 메트릭 수집.
# 임계값 초과 시 ~/.claude/pain-points.jsonl에 JSONL 레코드 append.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# --- stdin 읽기 ---
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -n "$INPUT" ] || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

[ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

# --- 설정 ---
PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"
TURN_THRESHOLD=30

# --- Git 정보 ---
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

# --- Transcript 분석 ---

# user 메시지 추출 (Task 2 조사 결과에 따라 .type 값 조정 필요)
USER_MESSAGES=$(jq -Rrs '
  split("\n")
  | map(select(length > 0) | fromjson?)
  | map(
      select(.type == "human")
      | (if (.message | type) == "string" then .message
         elif (.message | type) == "object" and ((.message.content | type) == "array") then
           [.message.content[]? | select(.type == "text") | .text] | join("\n")
         else ""
         end)
    )
  | map(select(length > 0))
' "$TRANSCRIPT_PATH" 2>/dev/null || echo '[]')

# 턴 수
TURNS=$(printf '%s' "$USER_MESSAGES" | jq 'length' 2>/dev/null || echo "0")

# 세션 시간 (분)
DURATION_MIN=$(jq -Rrs '
  split("\n")
  | map(select(length > 0) | fromjson?)
  | map(.timestamp // empty | select(. != null and . != ""))
  | if length > 1 then
      ( (last | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
      - (first | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) ) / 60 | floor
    else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")

# 교정 키워드 매칭
# ;; → high severity
# 아니(접속사 "아니면" 제외), 해야지, 그거 말고 → medium severity
CORRECTIONS=$(printf '%s' "$USER_MESSAGES" | jq '[
  .[] | select(
    test(";;")
    or test("^아니[^면]|^아니$|^아니 ")
    or test("해야지")
    or test("그거 말고")
  )
]' 2>/dev/null || echo '[]')

CORRECTION_COUNT=$(printf '%s' "$CORRECTIONS" | jq 'length' 2>/dev/null || echo "0")

# severity: ;; 감지 → high
HAS_DOUBLE_SEMI=$(printf '%s' "$CORRECTIONS" | jq '[.[] | select(test(";;"))] | length > 0' 2>/dev/null || echo "false")
SEVERITY="medium"
[ "$HAS_DOUBLE_SEMI" = "true" ] && SEVERITY="high"

# tool rejection (transcript에 rejection 표현이 있는지 — Task 2에서 확인한 형식 사용)
REJECTS=$(jq -Rrs '
  split("\n")
  | map(select(length > 0) | fromjson?)
  | map(select(
      (.type == "tool_result")
      and ((.error // "") | test("denied|permission"; "i"))
    ))
  | length
' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")

# --- 임계값 판정 ---
SHOULD_RECORD=false
[ "$CORRECTION_COUNT" -gt 0 ] && SHOULD_RECORD=true
[ "$REJECTS" -gt 0 ] && SHOULD_RECORD=true
[ "$TURNS" -gt "$TURN_THRESHOLD" ] && SHOULD_RECORD=true

if [ "$SHOULD_RECORD" = "true" ]; then
  DESC_PARTS=()
  [ "$CORRECTION_COUNT" -gt 0 ] && DESC_PARTS+=("교정 ${CORRECTION_COUNT}회")
  [ "$REJECTS" -gt 0 ] && DESC_PARTS+=("reject ${REJECTS}회")
  [ "$TURNS" -gt "$TURN_THRESHOLD" ] && DESC_PARTS+=("${TURNS}턴")
  DESCRIPTION=$(IFS=", "; echo "${DESC_PARTS[*]}")

  TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

  umask 077
  jq -nc \
    --arg ts "$TS" \
    --arg sid "${SESSION_ID:-unknown}" \
    --arg repo "$REPO" \
    --arg branch "$BRANCH" \
    --arg sev "$SEVERITY" \
    --argjson corrections "$CORRECTIONS" \
    --argjson rejects "$REJECTS" \
    --argjson turns "$TURNS" \
    --argjson dur "$DURATION_MIN" \
    --arg desc "$DESCRIPTION" \
    '{
      ts: $ts, session_id: $sid, repo: $repo, branch: $branch,
      source: "auto", severity: $sev,
      signals: { corrections: $corrections, rejects: ($rejects), turns: ($turns), duration_min: ($dur) },
      description: $desc, user_note: null
    }' >> "$PAIN_FILE"
fi

exit 0
```

```bash
chmod +x modules/shared/programs/claude/files/hooks/collect-pain-points.sh
```

- [ ] **Step 4: 테스트 재실행 — 성공 확인**

```bash
TEST_DIR=$(mktemp -d)
MOCK_TRANSCRIPT="$TEST_DIR/transcript.jsonl"

cat > "$MOCK_TRANSCRIPT" << 'JSONL'
{"type":"user","message":"Nix 설정 파일을 수정해줘","timestamp":"2026-03-28T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"네, 수정하겠습니다."}]},"timestamp":"2026-03-28T10:01:00Z"}
{"type":"user","message":"아니 그 파일 말고 다른 거","timestamp":"2026-03-28T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"죄송합니다."}]},"timestamp":"2026-03-28T10:03:00Z"}
{"type":"user","message":";;","timestamp":"2026-03-28T10:04:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"다시 확인하겠습니다."}]},"timestamp":"2026-03-28T10:05:00Z"}
JSONL

# 격리된 HOME 사용
export PAIN_POINTS_FILE="$TEST_DIR/pain-points.jsonl"

echo '{"session_id":"test-123","transcript_path":"'"$MOCK_TRANSCRIPT"'"}' | \
  bash modules/shared/programs/claude/files/hooks/collect-pain-points.sh

# 검증
echo "=== 결과 ==="
cat "$TEST_DIR/pain-points.jsonl"
echo ""
echo "=== severity 확인 (high 예상) ==="
jq -r '.severity' "$TEST_DIR/pain-points.jsonl"
echo "=== corrections 수 확인 (2 예상: '아니...' + ';;') ==="
jq '.signals.corrections | length' "$TEST_DIR/pain-points.jsonl"

rm -rf "$TEST_DIR"
```

Expected:
- `pain-points.jsonl`에 1개 레코드 생성
- `severity` = `"high"` (;; 감지)
- `corrections` 배열에 2개 항목 ("아니 그 파일 말고 다른 거", ";;")

- [ ] **Step 5: 임계값 미달 시 기록 안 함 확인 (깨끗한 세션)**

```bash
TEST_DIR=$(mktemp -d)
MOCK_TRANSCRIPT="$TEST_DIR/transcript.jsonl"

# 교정 키워드 없는 깨끗한 세션 (3턴 < 30)
cat > "$MOCK_TRANSCRIPT" << 'JSONL'
{"type":"user","message":"안녕하세요","timestamp":"2026-03-28T10:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"안녕하세요!"}]},"timestamp":"2026-03-28T10:01:00Z"}
{"type":"user","message":"감사합니다","timestamp":"2026-03-28T10:02:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"천만에요."}]},"timestamp":"2026-03-28T10:03:00Z"}
JSONL

export PAIN_POINTS_FILE="$TEST_DIR/pain-points.jsonl"

echo '{"session_id":"clean-session","transcript_path":"'"$MOCK_TRANSCRIPT"'"}' | \
  bash modules/shared/programs/claude/files/hooks/collect-pain-points.sh

# 파일이 생성되지 않아야 함
if [ -f "$TEST_DIR/pain-points.jsonl" ]; then
  echo "FAIL: 깨끗한 세션인데 pain point가 기록됨"
  cat "$TEST_DIR/pain-points.jsonl"
else
  echo "PASS: 깨끗한 세션 — 기록 없음"
fi

rm -rf "$TEST_DIR"
```

Expected: PASS — 파일 미생성

- [ ] **Step 6: 커밋**

```bash
git add modules/shared/programs/claude/files/hooks/collect-pain-points.sh
git commit -m "feat(pain): collect-pain-points.sh Stop hook — 자동 transcript 분석"
```

---

### Task 4: read-pain-points.sh (SessionStart hook — 읽기)

**Files:**
- Create: `modules/shared/programs/claude/files/hooks/read-pain-points.sh`

- [ ] **Step 1: 테스트용 mock pain-points.jsonl 생성 + 검증 명령 작성**

```bash
TEST_DIR=$(mktemp -d)
MOCK_PAIN="$TEST_DIR/pain-points.jsonl"

# 최근 3건: high 1, medium 1, manual 1
cat > "$MOCK_PAIN" << 'JSONL'
{"ts":"2026-03-27T10:00:00+00:00","session_id":"s1","repo":"nixos-config","branch":"feat/x","source":"auto","severity":"high","signals":{"corrections":[";;"],"rejects":0,"turns":45,"duration_min":38},"description":"교정 1회, 45턴","user_note":null}
{"ts":"2026-03-25T10:00:00+00:00","session_id":"s2","repo":"nixos-config","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니 그거 말고"],"rejects":0,"turns":28,"duration_min":20},"description":"교정 1회, 28턴","user_note":null}
{"ts":"2026-03-26T10:00:00+00:00","session_id":"s3","repo":"nixos-config","branch":"fix/y","source":"manual","severity":"medium","signals":{},"description":"수동 태깅: Edit 잘못된 파일","user_note":"Edit 잘못된 파일"}
JSONL

export PAIN_POINTS_FILE="$MOCK_PAIN"

echo '{"session_id":"new-session","source":"startup"}' | \
  bash modules/shared/programs/claude/files/hooks/read-pain-points.sh 2>&1; echo "EXIT: $?"
```

Expected: 스크립트 미존재로 실패.

- [ ] **Step 2: 실패 확인**

Run: 위의 명령 실행
Expected: FAIL — `No such file or directory`

- [ ] **Step 3: read-pain-points.sh 구현**

`modules/shared/programs/claude/files/hooks/read-pain-points.sh`:

```bash
#!/usr/bin/env bash
# Claude Code SessionStart Hook - Pain point 읽기
# stdin: JSON {session_id, source}
# stdout: JSON {hookSpecificOutput: {additionalContext: "..."}}
#
# 최근 7일 pain point를 severity별로 정렬하여 additionalContext로 주입.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -n "$INPUT" ] || exit 0

PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"

# 파일 없거나 비어있으면 skip
[ -f "$PAIN_FILE" ] && [ -s "$PAIN_FILE" ] || exit 0

# 7일 전 날짜 계산 (macOS: -v, Linux: -d)
SEVEN_DAYS_AGO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
  || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
  || exit 0)

# 최근 7일 항목 필터 + severity 정렬 + 최대 10건
CONTEXT=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" '
  map(select(.ts >= $cutoff))
  | sort_by(
      # severity 우선 (high=0, medium=1), 같으면 최신 우선
      (if .severity == "high" then "0" else "1" end) + .ts
    )
  | reverse
  | .[0:10]
  | if length == 0 then empty
    else
      # 그룹별 카운트
      (map(select(.severity == "high")) | length) as $high_count
      | (map(select(.severity == "medium" and .source == "auto")) | length) as $med_count
      | (map(select(.source == "manual")) | length) as $manual_count
      | . as $items
      |
      "## 최근 Pain Points (7일) -- \(length)건\n"
      + if $high_count > 0 then
          "\n### HIGH (\($high_count)건)\n"
          + ($items | map(select(.severity == "high"))
            | map("- [\(.ts[5:10]) 세션 \(.session_id[0:8])] \(.description)\n  └ repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
      + if $med_count > 0 then
          "\n### MEDIUM (\($med_count)건)\n"
          + ($items | map(select(.severity == "medium" and .source == "auto"))
            | map("- [\(.ts[5:10]) 세션 \(.session_id[0:8])] \(.description)\n  └ repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
      + if $manual_count > 0 then
          "\n### MANUAL (\($manual_count)건)\n"
          + ($items | map(select(.source == "manual"))
            | map("- [\(.ts[5:10]) 세션 \(.session_id[0:8])] \(.user_note // .description)\n  └ repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
    end
' "$PAIN_FILE" 2>/dev/null || true)

# 출력할 내용이 없으면 skip
[ -n "$CONTEXT" ] || exit 0

jq -n --arg ctx "$CONTEXT" \
  '{"hookSpecificOutput":{"additionalContext":$ctx}}'

exit 0
```

```bash
chmod +x modules/shared/programs/claude/files/hooks/read-pain-points.sh
```

- [ ] **Step 4: 테스트 재실행 — 성공 확인**

```bash
TEST_DIR=$(mktemp -d)
MOCK_PAIN="$TEST_DIR/pain-points.jsonl"

cat > "$MOCK_PAIN" << 'JSONL'
{"ts":"2026-03-27T10:00:00+00:00","session_id":"s1","repo":"nixos-config","branch":"feat/x","source":"auto","severity":"high","signals":{"corrections":[";;"],"rejects":0,"turns":45,"duration_min":38},"description":"교정 1회, 45턴","user_note":null}
{"ts":"2026-03-25T10:00:00+00:00","session_id":"s2","repo":"nixos-config","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니 그거 말고"],"rejects":0,"turns":28,"duration_min":20},"description":"교정 1회, 28턴","user_note":null}
{"ts":"2026-03-26T10:00:00+00:00","session_id":"s3","repo":"nixos-config","branch":"fix/y","source":"manual","severity":"medium","signals":{},"description":"수동 태깅: Edit 잘못된 파일","user_note":"Edit 잘못된 파일"}
JSONL

export PAIN_POINTS_FILE="$MOCK_PAIN"

RESULT=$(echo '{"session_id":"new-session","source":"startup"}' | \
  bash modules/shared/programs/claude/files/hooks/read-pain-points.sh)

echo "=== hookSpecificOutput ==="
echo "$RESULT" | jq '.'
echo ""
echo "=== additionalContext 내용 ==="
echo "$RESULT" | jq -r '.hookSpecificOutput.additionalContext'
echo ""
echo "=== HIGH 섹션 존재 확인 ==="
echo "$RESULT" | jq -r '.hookSpecificOutput.additionalContext' | grep -c "HIGH" && echo "PASS" || echo "FAIL"

rm -rf "$TEST_DIR"
```

Expected:
- hookSpecificOutput JSON 출력
- additionalContext에 HIGH / MEDIUM / MANUAL 섹션 포함
- 3건 표시

- [ ] **Step 5: 빈 파일 시 출력 없음 확인**

```bash
TEST_DIR=$(mktemp -d)
export PAIN_POINTS_FILE="$TEST_DIR/pain-points.jsonl"

RESULT=$(echo '{"session_id":"new","source":"startup"}' | \
  bash modules/shared/programs/claude/files/hooks/read-pain-points.sh)

if [ -z "$RESULT" ]; then
  echo "PASS: 빈 파일 — 출력 없음"
else
  echo "FAIL: 빈 파일인데 출력 있음: $RESULT"
fi

rm -rf "$TEST_DIR"
```

Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add modules/shared/programs/claude/files/hooks/read-pain-points.sh
git commit -m "feat(pain): read-pain-points.sh SessionStart hook — pain point 자동 읽기"
```

---

### Task 5: 정제 로직 (collect-pain-points.sh에 추가)

7일 이전 항목이 5건 이상이면 claude -p로 패턴 분석 → memory 승격.

**Files:**
- Modify: `modules/shared/programs/claude/files/hooks/collect-pain-points.sh` (하단에 추가)

- [ ] **Step 1: claude -p 플래그 확인**

```bash
claude -p --help 2>&1 | head -30
```

`--output-format` 플래그 존재 여부와 사용법을 확인. 없으면 plain text 파싱으로 대체.

- [ ] **Step 2: 정제 로직 테스트 — 5건 미만이면 skip 확인**

```bash
TEST_DIR=$(mktemp -d)
MOCK_PAIN="$TEST_DIR/pain-points.jsonl"

# 오래된 항목 3건 (< 5건 임계값)
for i in 1 2 3; do
  echo '{"ts":"2026-03-15T10:00:00+00:00","session_id":"old-'"$i"'","repo":"test","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니"],"rejects":0,"turns":10,"duration_min":5},"description":"교정 1회","user_note":null}' >> "$MOCK_PAIN"
done
# 최근 항목 1건
echo '{"ts":"2026-03-28T10:00:00+00:00","session_id":"new-1","repo":"test","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니"],"rejects":0,"turns":10,"duration_min":5},"description":"교정 1회","user_note":null}' >> "$MOCK_PAIN"

ARCHIVE_FILE="$TEST_DIR/pain-points.archive.jsonl"
export PAIN_POINTS_FILE="$MOCK_PAIN"
export PAIN_ARCHIVE_FILE="$ARCHIVE_FILE"

# collect 스크립트의 정제 로직만 테스트 (transcript 없이는 수집 부분은 skip됨)
echo '{"session_id":"x","transcript_path":"/nonexistent"}' | \
  bash modules/shared/programs/claude/files/hooks/collect-pain-points.sh 2>/dev/null || true

ORIGINAL_LINES=$(wc -l < "$MOCK_PAIN")
if [ "$ORIGINAL_LINES" -eq 4 ]; then
  echo "PASS: 5건 미만이라 정제 skip, 원본 4줄 유지"
else
  echo "FAIL: 원본이 변경됨 (${ORIGINAL_LINES}줄)"
fi

rm -rf "$TEST_DIR"
```

Expected: PASS — 4줄 유지, 아카이브 없음

- [ ] **Step 3: collect-pain-points.sh에 정제 로직 추가**

`exit 0` 바로 위에 다음 섹션을 삽입:

```bash
# --- 정제: 7일 이전 항목 처리 ---
ARCHIVE_FILE="${PAIN_ARCHIVE_FILE:-$HOME/.claude/pain-points.archive.jsonl}"

if [ -f "$PAIN_FILE" ] && [ -s "$PAIN_FILE" ]; then
  SEVEN_DAYS_AGO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || true)

  if [ -n "$SEVEN_DAYS_AGO" ]; then
    OLD_COUNT=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" \
      'map(select(.ts < $cutoff)) | length' "$PAIN_FILE" 2>/dev/null || echo "0")

    if [ "$OLD_COUNT" -ge 5 ]; then
      OLD_ENTRIES=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" \
        'map(select(.ts < $cutoff))' "$PAIN_FILE" 2>/dev/null)

      # memory 디렉토리 탐색 (git repo 기반)
      REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$REPO_ROOT" ]; then
        ENCODED=$(printf '%s' "$REPO_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
        MEMORY_DIR="$HOME/.claude/projects/$ENCODED/memory"
      else
        MEMORY_DIR=""
      fi

      # claude -p로 패턴 분석 (실패 시 그냥 아카이브만 수행)
      DISTILLED=false
      if command -v claude >/dev/null 2>&1 && [ -n "$MEMORY_DIR" ] && [ -d "$MEMORY_DIR" ]; then
        PROMPT="아래 pain point 로그를 분석하세요. 반복 패턴이 있으면 feedback memory 파일 내용을 생성하세요.

규칙:
- 2회 이상 반복되는 패턴만 memory로 추출
- 1회성 항목은 무시
- 각 memory의 name은 pain- 접두사
- 출력 형식: JSON {\"memories\": [{\"filename\": \"pain-xxx.md\", \"content\": \"---\\nname: ...\\n---\\n본문\"}]}
- memory가 없으면 {\"memories\": []}

로그:
$(printf '%s' "$OLD_ENTRIES")"

        RESULT=$(printf '%s' "$PROMPT" | timeout 60 claude -p --output-format json 2>/dev/null || echo "")

        if [ -n "$RESULT" ]; then
          # memory 파일 생성
          MEMORY_COUNT=$(printf '%s' "$RESULT" | jq '.memories | length' 2>/dev/null || echo "0")
          if [ "$MEMORY_COUNT" -gt 0 ]; then
            for i in $(seq 0 $((MEMORY_COUNT - 1))); do
              FNAME=$(printf '%s' "$RESULT" | jq -r ".memories[$i].filename" 2>/dev/null)
              MCONTENT=$(printf '%s' "$RESULT" | jq -r ".memories[$i].content" 2>/dev/null)
              if [ -n "$FNAME" ] && [ -n "$MCONTENT" ] && [ "$FNAME" != "null" ]; then
                printf '%s\n' "$MCONTENT" > "$MEMORY_DIR/$FNAME"
                # MEMORY.md 인덱싱
                MDESC=$(printf '%s' "$MCONTENT" | grep '^description:' | head -1 | sed 's/^description: *//')
                if [ -f "$MEMORY_DIR/MEMORY.md" ] && ! grep -qF "$FNAME" "$MEMORY_DIR/MEMORY.md"; then
                  printf -- '- [%s](%s) — %s\n' "$FNAME" "$FNAME" "${MDESC:-pain point 자동 정제}" >> "$MEMORY_DIR/MEMORY.md"
                fi
              fi
            done
            DISTILLED=true
          fi
        fi
      fi

      # 오래된 항목을 archive로 이동 (정제 성공 여부와 무관)
      jq -rs --arg cutoff "$SEVEN_DAYS_AGO" \
        '.[] | select(.ts < $cutoff)' "$PAIN_FILE" >> "$ARCHIVE_FILE" 2>/dev/null || true

      # pain-points.jsonl에서 오래된 항목 제거 (atomic write)
      tmp=$(mktemp)
      jq -rs --arg cutoff "$SEVEN_DAYS_AGO" \
        '[.[] | select(.ts >= $cutoff)] | .[]' "$PAIN_FILE" > "$tmp" 2>/dev/null \
        && mv "$tmp" "$PAIN_FILE" \
        || rm -f "$tmp"
    fi
  fi
fi

# 아카이브 30일 초과 정리
if [ -f "$ARCHIVE_FILE" ] && [ -s "$ARCHIVE_FILE" ]; then
  THIRTY_DAYS_AGO=$(date -u -v-30d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || date -u -d "30 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || true)
  if [ -n "$THIRTY_DAYS_AGO" ]; then
    tmp=$(mktemp)
    jq -rs --arg cutoff "$THIRTY_DAYS_AGO" \
      '[.[] | select(.ts >= $cutoff)] | .[]' "$ARCHIVE_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$ARCHIVE_FILE" \
      || rm -f "$tmp"
  fi
fi
```

- [ ] **Step 4: 테스트 — 5건 이상이면 archive로 이동 확인**

```bash
TEST_DIR=$(mktemp -d)
MOCK_PAIN="$TEST_DIR/pain-points.jsonl"

# 오래된 항목 6건 (>= 5건 임계값)
for i in 1 2 3 4 5 6; do
  echo '{"ts":"2026-03-15T10:00:00+00:00","session_id":"old-'"$i"'","repo":"test","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니"],"rejects":0,"turns":10,"duration_min":5},"description":"교정 1회","user_note":null}' >> "$MOCK_PAIN"
done
# 최근 항목 1건
echo '{"ts":"2026-03-28T10:00:00+00:00","session_id":"new-1","repo":"test","branch":"main","source":"auto","severity":"medium","signals":{"corrections":["아니"],"rejects":0,"turns":10,"duration_min":5},"description":"교정 1회","user_note":null}' >> "$MOCK_PAIN"

export PAIN_POINTS_FILE="$MOCK_PAIN"
export PAIN_ARCHIVE_FILE="$TEST_DIR/pain-points.archive.jsonl"

echo '{"session_id":"x","transcript_path":"/nonexistent"}' | \
  bash modules/shared/programs/claude/files/hooks/collect-pain-points.sh 2>/dev/null || true

REMAINING=$(wc -l < "$MOCK_PAIN" 2>/dev/null || echo "0")
ARCHIVED=$(wc -l < "$TEST_DIR/pain-points.archive.jsonl" 2>/dev/null || echo "0")

echo "남은 항목: $REMAINING (1 예상)"
echo "아카이브: $ARCHIVED (6 예상)"

if [ "$REMAINING" -eq 1 ] && [ "$ARCHIVED" -eq 6 ]; then
  echo "PASS"
else
  echo "FAIL"
fi

rm -rf "$TEST_DIR"
```

Expected: PASS — 남은 1건, 아카이브 6건

- [ ] **Step 5: 커밋**

```bash
git add modules/shared/programs/claude/files/hooks/collect-pain-points.sh
git commit -m "feat(pain): collect-pain-points.sh에 7일 정제 + archive 로직 추가"
```

---

### Task 6: Nix 통합 (settings.json + default.nix)

**Files:**
- Modify: `modules/shared/programs/claude/files/settings.json`
- Modify: `modules/shared/programs/claude/default.nix`

- [ ] **Step 1: settings.json에 hook 항목 추가**

`modules/shared/programs/claude/files/settings.json`의 `"Stop"` 배열에 collect hook 추가, `"SessionStart"` 배열에 read hook 추가.

Stop 배열 (기존 stop-notification.sh, nrs-session-cleanup.sh 뒤에):

```json
{
  "matcher": "",
  "hooks": [
    {
      "type": "command",
      "command": "~/.claude/hooks/collect-pain-points.sh"
    }
  ]
}
```

주의: 기존 Stop 배열은 matcher=""에 hooks 2개가 배열로 들어있음. 새 항목은 **별도 matcher 객체**로 추가하여 기존 hooks에 영향을 주지 않음.

SessionStart 배열 (기존 session-init-icons.sh 뒤에):

```json
{
  "matcher": "",
  "hooks": [
    {
      "type": "command",
      "command": "~/.claude/hooks/read-pain-points.sh"
    }
  ]
}
```

- [ ] **Step 2: default.nix에 symlink 3개 추가**

`modules/shared/programs/claude/default.nix`의 `home.file` 블록에 추가:

```nix
# Pain point collection hooks
".claude/hooks/collect-pain-points.sh".source =
  config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/collect-pain-points.sh";
".claude/hooks/read-pain-points.sh".source =
  config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/read-pain-points.sh";

# pain 스킬 (user-scope)
".claude/skills/pain".source =
  config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/pain";
```

fragile-hardcoding-guard.sh symlink 아래, assets 위에 추가.

- [ ] **Step 3: 커밋**

```bash
git add modules/shared/programs/claude/files/settings.json modules/shared/programs/claude/default.nix
git commit -m "feat(pain): Nix 통합 — hooks + skill symlink 추가"
```

---

### Task 7: nrs + End-to-end 검증

**Files:**
- 없음 (검증만)

- [ ] **Step 1: nrs 실행**

```bash
nrs
```

빌드 성공 확인. 실패하면 에러 메시지를 확인하고 Task 6에서 수정.

- [ ] **Step 2: symlink 생성 확인**

```bash
ls -la ~/.claude/hooks/collect-pain-points.sh
ls -la ~/.claude/hooks/read-pain-points.sh
ls -la ~/.claude/skills/pain/SKILL.md
```

3개 모두 symlink이고 대상 파일이 존재하는지 확인.

- [ ] **Step 3: hook 실행 권한 확인**

```bash
test -x ~/.claude/hooks/collect-pain-points.sh && echo "OK: collect" || echo "FAIL: collect not executable"
test -x ~/.claude/hooks/read-pain-points.sh && echo "OK: read" || echo "FAIL: read not executable"
```

실행 권한이 없으면 소스 파일에 `chmod +x` 필요.

- [ ] **Step 4: /pain 스킬 수동 테스트**

새 Claude Code 세션에서:

```
/pain 테스트 pain point — nrs 후 검증
```

이후 확인:

```bash
tail -1 ~/.claude/pain-points.jsonl | jq '.'
```

`source: "manual"`, `user_note`에 입력한 메모가 들어있는지 확인.

- [ ] **Step 5: SessionStart hook 수동 테스트**

새 Claude Code 세션을 시작하면 시스템 컨텍스트에 "최근 Pain Points" 섹션이 보이는지 확인.
(Step 4에서 수동 pain point를 기록했으므로 1건 이상 표시되어야 함.)

- [ ] **Step 6: Stop hook 자동 감지 테스트**

세션에서 의도적으로 교정 키워드를 사용한 후 세션을 종료:
1. Claude에게 잘못된 작업을 시키고 "아니 그거 말고" 로 교정
2. 세션 종료 (Ctrl+D 또는 /exit)
3. 확인:

```bash
tail -1 ~/.claude/pain-points.jsonl | jq '.'
```

`source: "auto"`, `corrections` 배열에 교정 키워드가 포함되어 있는지 확인.
