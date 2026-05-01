# File Mode Selection

PRD는 **Single-file mode** 또는 **Split-file mode**로 작성한다. 사용자가 명시적으로 지정하지 않으면 자동 선택한다.

## Single-file mode

기능이 한눈에 스캔 가능한 경우 단일 파일로 작성한다:

- Phase 3개 이하 (짧은 phase)
- 단일 도메인 또는 워크플로
- 긴 phase 체크리스트가 없음
- Discovery note가 master PRD 안에 편하게 들어감

**경로**: `.claude/prds/prd-[feature-name].md`

## Split-file mode

다음 조건 중 하나라도 만족하면 기본값으로 split-file을 사용한다:

- Phase가 **4개 이상**
- 어느 phase의 implementation 항목이 대략 10-12개 초과
- Discovery note가 master PRD의 집중력을 방해
- 여러 도메인이 관여 (data model, backend, frontend, migration, permission, async job, observability, rollout, billing 등)
- 구현 중 계획이 크게 바뀔 가능성
- Master PRD가 너무 길어 개발자가 읽기를 포기할 가능성

**경로 구조**:

- Master PRD: `.claude/prds/prd-[feature-name].md`
- Phase 디렉토리: `.claude/prds/prd-[feature-name]/`
- Context 파일 (선택): `.claude/prds/prd-[feature-name]/context.md`
- Phase 파일: `.claude/prds/prd-[feature-name]/phase-01-[phase-name].md` 등

## Split-file 작성 원칙

- Split-file 모드에서는 master PRD와 모든 초기 phase 파일을 **동일한 실행에서** 생성한다.
- 상대 링크를 사용한다.
- Master PRD에는 product intent, 요구사항, 글로벌 규칙, 상태, phase index, final review, open question, change log만 둔다.
- 상세 phase 체크리스트는 phase 파일에 둔다.
- Phase 종료 시 해당 phase 파일 갱신 + master PRD 갱신 + 새로 드러난 사실이 있으면 뒤 phase 파일도 revise.

## 모드 전환

File mode를 바꿔야 하면:

1. Master 경로는 stable하게 유지.
2. Phase 파일을 필요에 따라 생성/삭제.
3. 모든 링크를 갱신.
4. Status(`- [ ]` / `- [x]`)를 보존.
5. Change Log에 "File mode migrated: Single → Split" 식으로 기록.

## 자동 판정 플로우

```
Phase가 4개 이상인가?                          yes → Split
  no ↓
어느 phase의 implementation 항목이 10개 초과?  yes → Split
  no ↓
Discovery가 master PRD에 편하게 들어가는가?    no  → Split
  yes ↓
여러 도메인이 관여하는가?                      yes → Split
  no ↓
구현 중 계획이 크게 바뀔 가능성이 큰가?        yes → Split
  no ↓
→ Single
```

사용자가 "single로 유지해" 또는 "split으로 나눠줘"라고 명시하면 그 지시를 우선한다.
