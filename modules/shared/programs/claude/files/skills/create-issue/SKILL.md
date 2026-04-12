---
name: create-issue
argument-hint: "[issue title or description (optional)]"
description: |
  Create a structured GitHub issue with auto-enriched labels.
  Trigger: '이슈 등록', '이슈 만들어', 'todo 등록', '버그 등록', '이슈 추가'.
  NOT for CIR/ADR (use documenting-intent). NOT for PR 본문 (use create-pr).
---

# 이슈 등록

`$ARGUMENTS`를 이슈 제목, 설명, 또는 작업 내용으로 수신한다.
텍스트가 제공되면 이슈 제목/설명으로 사용하고,
비어있으면 대화 컨텍스트에서 이슈 내용을 추출한다.

## 빠른 참조

| 항목 | 설명 |
|------|------|
| 입력 | 이슈 제목 또는 설명 (선택). 비어있으면 대화 컨텍스트에서 추출 |
| 출력 | 구조적 이슈 등록 + URL 반환 |
| 핵심 도구 | 코드베이스 검색, `gh` CLI |
| 범위 | 등록 전용. 조회/감사/라이프사이클은 `gh` CLI를 직접 사용 |

## 절차

### Step 1 — 코드베이스 탐색

이슈 내용을 기반으로 관련 컨텍스트를 수집한다 (Summary A1/Context A2 작성에 필요). LLM 친화성 체크리스트 A 섹션 참조 ([../write-handoff/references/llm-friendly-checklist.md](../write-handoff/references/llm-friendly-checklist.md)).

- **(a) 관련 파일 탐색**: 이슈에 언급된 경로는 `Read`로, 모듈/키워드는 `Glob`/`Grep`으로 탐색.
  예: `Glob "**/*.nix"`, `Grep -n "<키워드>" modules/`, `find . -name "*.nix" -path "*<모듈>*"`.
- **(b) 관련 이슈 검색**: `gh issue list --search "<키워드>" --state all --limit 20`으로 중복/관련 이슈 확인.
- **(c) 관련 커밋 확인**: `git log --oneline -20 -- <관련 경로>` 또는 `git log --grep="<키워드>"`.

### Step 2 — 템플릿 작성

`references/issue-template.md`를 참조하여 이슈 본문을 작성한다.

**필수 섹션** (항상 작성):
- **Summary**: 1-2 문장으로 what + why 요약 (체크리스트 A1)
- **Context**: 현 상태 → 문제점 → 필요성 순으로 서술 (체크리스트 A2)
- **References**: 비자명 주장의 출처 링크 최소 1개 이상 (체크리스트 B1/B4). 공식 docs URL, repo 내부 파일 경로(`path/to/file.nix:LINE`), 관련 이슈/커밋(`#NNN`/`abc1234`). 근거 부재 시 `[UNVERIFIED]` 라벨로 대체.
- **Proposed Changes**: 체크박스(`- [ ]`) 형태의 구체적 변경 계획

**선택 섹션** (판단 기준에 따라 포함):
- **PoC / Reproduction**: 재현이 중요한 주장(버그 리포트 등)에 6필드 포함 — `환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준` (체크리스트 C1)
- **Related Commits**: `$ARGUMENTS` 또는 대화 컨텍스트에 커밋 해시가 언급되었거나, Step 1(c)에서 직접 관련 커밋을 발견한 경우
- **Affected Files**: 변경 대상 파일이 여러 개인 경우 (테이블 형식)
- **Notes**: 추가 참고사항(제약사항, 관련 이슈 번호, YAGNI 판단 근거 등)이 있는 경우

### Step 3 — Anti-hallucination 자체 검증

작성된 이슈 본문에 대해 다음을 수행한다 (LLM 친화성 체크리스트 E1/E2 참조).

- **E1. `[UNVERIFIED]` 라벨**: 코드베이스 직접 확인 또는 출처 링크가 없는 모든 주장에 `[UNVERIFIED]` 라벨을 붙이거나 삭제한다. 근접 근거로부터의 추론은 `[INFERRED]`, 두 출처 상충은 `[CONFLICTING]`. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [MetaFaith (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1505/).
- **E2. Self-verification 패스 (CoVe 경량)**: 초안의 비자명 주장을 질문으로 변환 → `Read`/`Grep`/`gh` 재실행으로 독립 확인 → 불일치 또는 근거 부재 시 `[UNVERIFIED]` 라벨 또는 삭제. 출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495).

### Step 4 — 라벨 자동 결정

`references/label-taxonomy.md`를 참조하여 라벨을 결정한다.

1. `gh label list`로 기존 area 라벨 목록을 조회한다.
2. 이슈 내용에서 적합한 area를 자동 매칭한다 (기존 area에서만 선택).
3. 매칭되는 area가 없으면 **area 없이 등록하고 사용자에게 알린다** (자동 생성 금지).
4. priority는 이슈 내용의 긴급도/영향도를 기반으로 자동 판단한다 (high/medium/low).
5. GitHub 기본 라벨(enhancement/bug/documentation 등)을 이슈 유형에 맞게 선택한다.

### Step 5 — 등록 및 확인

1. 등록 전 **제목, 라벨 조합을 사용자에게 보여주고 확인**을 받는다.
2. 확인 후 `gh issue create`를 **`--body-file`로 실행**한다. 본문은 임시 파일에 저장 후 전달. 실패 시 Step 6으로 진행하지 않는다.
   ```bash
   # BSD/macOS mktemp는 템플릿 끝(trailing)에 XXXXXX가 와야 랜덤 치환함.
   # 확장자 없이 랜덤 파일 생성 — gh issue create --body-file은 확장자 무관.
   umask 077
   ISSUE_BODY=$(mktemp -t issue-body.XXXXXX) || { echo "ERROR: mktemp 실패"; exit 1; }
   # <작성된 본문>을 $ISSUE_BODY에 기록 (Write 도구)

   # gh issue create — 성공 시 URL 캡처, 실패 시 본문 경로/미리보기 출력 후 exit 1
   if ISSUE_URL=$(gh issue create --title "<제목>" --label "<라벨>" --body-file "$ISSUE_BODY"); then
     echo "ISSUE_URL=$ISSUE_URL"
     rm -f "$ISSUE_BODY"
   else
     rc=$?
     echo "ERROR: gh issue create 실패 (exit $rc)"
     echo "ISSUE_BODY_PATH=$ISSUE_BODY  # 본문 보존됨 (재시도 시 재사용)"
     echo "--- 본문 미리보기 (상위 20줄, shell 세션 외 접근 가능하도록 stdout에 표시) ---"
     head -20 "$ISSUE_BODY"
     echo "---"
     echo "재시도 명령 (동일 shell 세션 또는 ISSUE_BODY_PATH 값을 직접 입력):"
     echo "  gh issue create --title '<제목>' --label '<라벨>' --body-file \"\$ISSUE_BODY_PATH\""
     echo "**Step 6(이행 가이드 연계)은 이슈 등록 완료 전에는 진행하지 않는다.**"
     exit 1
   fi
   ```
3. 반환된 `ISSUE_URL`이 실제 GitHub URL(`https://github.com/.../issues/N`)인지 확인. 실패 시 Step 6 진행 금지.

### Step 6 — LLM 이행 가이드 연계

**진입 가드**: Step 5가 성공적으로 `ISSUE_URL` 을 반환했는지 확인한다. 반환이 없거나 `ERROR:` 출력이 있었다면 **Step 6으로 진행하지 않는다** — 존재하지 않는 이슈 번호로 `/write-handoff`를 호출하면 handoff comment가 엉뚱한 곳에 게시되거나 오류로 중단된다.

**호출 맥락 확인**: plan-with-questions에서 호출된 경우(Step I-5), 이 Step을 건너뛴다.
(plan-with-questions Step I-6에서 통합 선택지로 제안하므로 중복 방지.)

이슈 생성이 완료되면, AskUserQuestion으로 사용자에게 묻는다:

"LLM 이행 가이드를 작성할까요?"

- 사용자가 승인 → `/write-handoff <생성된 이슈 번호>` 스킬을 실행한다.
- 사용자가 거부 → 이슈 URL 반환 후 종료한다.

## Title Conventions

| Prefix | Use |
|--------|-----|
| `feat:` | 새 기능, 개선 |
| `fix:` | 버그 수정 |
| `refactor:` | 구조 변경 (동작 불변) |
| `test:` | 테스트 추가/수정 |
| `docs:` | 문서 |
| `chore:` | 기타 유지보수 |

## 주의사항

- 이슈 본문에 시크릿/credential/API 키를 포함하지 않는다. `.age` 복호화 값, `.env` 내용은 파일 경로만 참조한다.
- 조회(`gh issue list`), 감사(audit), 라이프사이클(close/reopen/edit), 라벨 관리(CRUD)는 이 스킬의 범위 밖이다. `gh` CLI를 직접 사용한다.
- `gh issue create` 실행 시 본문은 **`--body-file`로 전달**한다. HEREDOC(`$(cat <<'EOF' ... EOF)`) 방식은 본문 내부에 PoC/Reproduction 섹션의 nested `cat <<'EOF'` 예시나 독립 `EOF` 라인이 포함될 때 outer heredoc가 조기 종료되어 등록이 실패하거나 본문이 잘린다. `PoC / Reproduction` 섹션(issue-template)의 shell 재현 스니펫이 기본 기능이므로 HEREDOC 전달은 금지.
- **근거 없는 주장 금지**: 코드베이스 직접 확인 또는 출처 링크가 없는 주장은 `[UNVERIFIED]` 라벨을 붙이거나 삭제한다 (체크리스트 E1). `<!-- 미검증 -->` HTML 주석은 DEPRECATED.

## 참조 자료

- **[references/issue-template.md](references/issue-template.md)** -- 이슈 템플릿 (필수 섹션: Summary/Context/References/Proposed Changes + 선택 섹션: PoC/Related Commits/Affected Files/Notes) + 섹션별 작성 가이드 + 작성 예시
- **[references/label-taxonomy.md](references/label-taxonomy.md)** -- 라벨 체계 상세 (색상 코드, 판단 기준, 설계 근거)
- **[LLM 친화성 체크리스트](../write-handoff/references/llm-friendly-checklist.md)** -- `create-issue`/`write-handoff` 공유. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`). 공식 docs/학술 출처 링크 포함
