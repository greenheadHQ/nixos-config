# File Mode Selection

PRD는 Single-file mode 또는 Split-file mode로 작성한다. 사용자가 명시적으로 지정하지 않으면 자동 선택한다.

## Single-file mode

기능이 한눈에 스캔 가능한 경우 단일 파일로 작성한다:

- Phase 3개 이하 (짧은 phase)
- 단일 도메인 또는 워크플로
- 긴 phase 체크리스트가 없음
- Discovery note가 master PRD 안에 편하게 들어감

경로: `.claude/prds/prd-[feature-name].md`

## Split-file mode

다음 조건 중 하나라도 만족하면 기본값으로 split-file을 사용한다:

- Phase가 4개 이상
- 어느 phase의 implementation 항목이 대략 10-12개 초과
- Discovery note가 master PRD의 집중력을 방해
- 여러 도메인이 관여 (data model, backend, frontend, migration, permission, async job, observability, rollout, billing 등)
- 구현 중 계획이 크게 바뀔 가능성
- Master PRD가 너무 길어 개발자가 읽기를 포기할 가능성

경로 구조:

- Master PRD: `.claude/prds/prd-[feature-name].md`
- Phase 디렉토리: `.claude/prds/prd-[feature-name]/`
- Context 파일 (선택): `.claude/prds/prd-[feature-name]/context.md`
- Phase 파일: `.claude/prds/prd-[feature-name]/phase-01-[phase-name].md` 등

## 경로 slug 안전 규칙

`[feature-name]`과 `[phase-name]`은 사용자 입력, 이슈 제목, phase 제목에서 직접 사용하지 않고 slug로 정규화한다.

- slug는 lowercase `[a-z0-9-]+` basename만 허용한다.
- `.`, `..`, slash(`/`), backslash(`\`), 공백, shell/path metacharacter가 포함된 값은 거부하고 안전한 slug를 다시 생성한다.
- 새 파일 자체가 아직 없을 수 있으므로 repo root와 `.claude/prds/` parent directory처럼 이미 존재해야 하는 경로만 canonicalize한다. 그 parent가 repo 안의 `.claude/prds/`와 일치함을 확인한 뒤 safe basename을 join한다.
- 최종 master PRD 경로와 phase 파일 경로의 containment는 "canonical parent + safe basename"으로 판정한다. 존재하지 않는 최종 파일을 `realpath`/`readlink -f` 대상으로 요구하지 않는다.
- Split mode의 phase 파일은 `.claude/prds/prd-<feature>/phase-NN-<phase>.md` 형태만 허용한다. `NN`은 zero-padded positive integer다.
- 동일 파일 또는 디렉토리가 이미 있으면 같은 `Source`/PRD identity의 resumable artifact인지 먼저 확인한다. 같으면 기존 PRD에 bind하고, unrelated collision이면 `-2`, `-3` 같은 숫자 suffix를 slug 뒤에 붙인다. suffix 적용 후에도 같은 안전 검사를 다시 통과해야 한다.
- 안전 경로를 만들 수 없거나 canonical containment 검사를 통과하지 못하면 PRD 파일을 쓰지 않고 BLOCKED 처리한다.

## Split-file 작성 원칙

- Split-file 모드에서는 master PRD와 모든 초기 phase 파일을 동일한 실행에서 생성한다.
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
