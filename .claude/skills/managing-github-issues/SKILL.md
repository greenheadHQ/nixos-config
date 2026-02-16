---
name: managing-github-issues
description: |
  This skill should be used when the user asks to "create an issue",
  "이슈 등록", "이슈 만들어", "todo 만들어", "이슈 조회", "list issues",
  "todo 확인", "이슈 닫기", "close issue", "이슈 다시 열기", "reopen issue",
  "이슈 업데이트", "edit issue", "라벨 추가", "add label",
  "backlog 확인", "기술 부채", "tech debt", "이슈 감사", "triage",
  or needs to manage GitHub Issues in the shren207/nixos-config repository.
  Triggers: "github issue", "이슈", "todo", "라벨", "label",
  "backlog", "priority", "할 일", "개선사항", "등록", "조회",
  "이슈 상태", "issue status", "남은 할 일", "부채", "audit", "reopen".
---

# Managing GitHub Issues

## Purpose

`shren207/nixos-config` 레포지토리의 GitHub Issues를 `gh` CLI로 관리하는 스킬.
이슈 생성, 조회, 라이프사이클 관리, 감사(audit) 절차를 정의한다.

**모든 이슈는 반드시 `references/issue-template.md`의 고정 템플릿을 사용해야 한다.**
포맷 일관성이 LLM 파싱과 자동화의 핵심이므로, 템플릿을 임의로 변경하지 않는다.

## Repository

- **Repo**: `shren207/nixos-config`
- **CLI**: 모든 작업은 `gh` CLI로 수행 (웹 UI 사용 금지)

## Label Taxonomy

모든 이슈에 **1개 priority + area(해당 시) + 선택적 기본 라벨** 조합을 부착한다.

- **Priority** (필수): `priority:high` / `priority:medium` / `priority:low`
- **Area** (해당 시): `area:scalability` / `area:testing` / `area:security`
- **Default**: GitHub 기본 라벨 (`enhancement`, `bug`, `documentation` 등) 병용

area 라벨이 이슈 도메인과 맞지 않으면 생략 가능.
동일 도메인 이슈가 2개 이상 반복되면 새 area 라벨 추가를 검토한다.
상세 색상 코드, 판단 기준, 추가/삭제 절차는 `references/label-taxonomy.md` 참조.

## Issue Creation

### Workflow

1. `references/issue-template.md`에서 고정 템플릿 확인
2. 템플릿의 모든 섹션을 빠짐없이 채움 (해당 없는 섹션은 "N/A" 기재)
3. title에 conventional prefix 적용
4. 적절한 label 조합 선택 (priority 필수 + area 해당 시 + 기본 라벨)
5. **생성 전 검증**: `references/issue-template.md`의 6개 필수 섹션과 포맷 규칙(테이블, 체크박스) 준수 여부 확인.
6. `gh issue create`로 등록

### Title Conventions

| Prefix | Use |
|--------|-----|
| `feat:` | 새 기능, 개선 |
| `fix:` | 버그 수정 |
| `refactor:` | 구조 변경 (동작 불변) |
| `test:` | 테스트 추가/수정 |
| `docs:` | 문서 |
| `chore:` | 기타 유지보수 |

### gh CLI Command

```bash
gh issue create \
  --title "feat: 제목" \
  --label "enhancement,area:testing,priority:medium" \
  --body "$(cat <<'EOF'
## Summary
...
(references/issue-template.md의 고정 템플릿을 채워서 사용)
EOF
)"
```

## Issue Lifecycle

### Close

```bash
gh issue close <number> --reason "completed"     # 완료
gh issue close <number> --reason "not planned"    # 더 이상 유효하지 않음
gh issue close <number> --comment "사유"          # 사유와 함께 닫기
```

### Reopen

```bash
gh issue reopen <number>                          # 잘못 닫은 경우
gh issue reopen <number> --comment "재개 사유"
```

### Edit

```bash
gh issue edit <number> --title "새 제목"
gh issue edit <number> --add-label "priority:high" --remove-label "priority:low"
gh issue edit <number> --body "새 본문"
```

닫을 때 priority 라벨은 유지한다 (과거 우선순위 이력 추적용).

## Issue Querying

### List Commands

```bash
gh issue list                                    # 전체 open
gh issue list --label "priority:high"            # 우선순위별
gh issue list --label "area:security"            # 도메인별
gh issue list --label "priority:high,area:security"  # 조합
gh issue list --state all                        # closed 포함
gh issue list --search "keyword"                 # 키워드 검색
```

### View Detail

```bash
gh issue view <number>                 # 상세 보기
gh issue view <number> --comments      # 댓글 포함
```

### Quick Status Check

`gh issue list`의 기본 제한은 30개이므로, 정확한 카운트에는 `--limit` 지정 필수.

```bash
# 전체 현황 (open count by priority)
gh issue list --label "priority:high" --json number --jq length --limit 500
gh issue list --label "priority:medium" --json number --jq length --limit 500
gh issue list --label "priority:low" --json number --jq length --limit 500
```

## Issue Audit (감사)

기술 부채 현황 파악, 이슈 유효성 검증 시 사용하는 절차.

### 전체 기술 부채 확인

```bash
# 모든 open 이슈 목록 (title + labels + 생성일)
gh issue list --limit 500 --json number,title,labels,createdAt
```

### 개별 이슈 검증 체크리스트

각 open 이슈에 대해 아래 항목을 확인한다:

1. **유효성**: 이슈가 아직 유효한가? (이미 해결되었거나 환경이 변경되지 않았는지)
2. **타당성**: 제안된 변경이 여전히 합리적인가?
3. **우선순위**: 현재 상황에서 priority 라벨이 적절한가? (상향/하향 필요?)
4. **정확성**: Affected Files, Proposed Changes가 현재 코드베이스와 일치하는가?
5. **중복**: 다른 이슈와 겹치거나 이미 다른 이슈에서 해결되지 않았는가?
6. **완료 여부**: Proposed Changes의 체크박스 중 이미 완료된 항목이 있는가?

검증 후 조치:
- 이미 해결됨 → `gh issue close <number> --reason "completed" --comment "사유"`
- 더 이상 유효하지 않음 → `gh issue close <number> --reason "not planned" --comment "사유"`
- 우선순위 변경 필요 → `gh issue edit <number> --add-label "priority:high" --remove-label "priority:low"`
- 내용 업데이트 필요 → `gh issue edit <number> --body "수정된 본문"` (고정 템플릿 유지)

## Label Management

라벨 추가/수정/삭제 절차는 `references/label-taxonomy.md` 참조.

이슈에 라벨 부착/제거:

```bash
gh issue edit <number> --add-label "area:testing"
gh issue edit <number> --remove-label "priority:low"
```

## Additional Resources

### Reference Files

- **`references/label-taxonomy.md`** — 라벨 체계 상세 (색상 코드, 판단 기준, 추가/삭제 절차, 설계 근거)
- **`references/issue-template.md`** — **고정 이슈 템플릿** + 섹션별 작성 가이드 + 작성 예시
