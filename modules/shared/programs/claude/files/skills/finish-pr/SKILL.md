---
name: finish-pr
argument-hint: "[pr-number|pr-url|branch]"
description: |
  PR 머지 후 종결 절차를 수행한다. 대상 PR 확인, CI 상태 확인, 퀴즈 게이트(finding-unknowns 방법론 적용 작업), squash merge, main pull 후 로컬 실측 검증, PR 후속 코멘트, 관련 이슈 동기화, 산출물 위생 점검, worktree cleanup까지 다룬다.
  Trigger: '머지해줘', 'squash merge', '머지 후 정리', 'PR 마무리', 'PR 종결', 'finish-pr'.
  NOT for PR 생성 (use create-pr). NOT for PR 코멘트 처리 (use review-pr-feedback).
---

# PR 종결

사용자 인자로 PR 번호, PR URL, 또는 브랜치 힌트를 수신하면 그 값을 우선하고, 없으면 현재 브랜치에서 대상 PR을 추론한다.

## 원칙

- 현재 레포의 `CLAUDE.md`, `AGENTS.md`, 스킬 문서, 빌드 관례가 이 스킬보다 우선한다.
- STOP 지점에 도달하면 이후 GitHub 쓰기, 이슈 close, 워크트리 정리를 진행하지 않고 사용자에게 원인과 다음 선택지를 보고한다.
- GitHub 본문이 길거나 셸 해석 문자가 섞이면 임시 파일과 `--body-file`을 사용한다.
- 검증 실패도 숨기지 않는다. 이미 머지된 뒤 검증이 실패하면 실패 명령, 핵심 stderr/stdout, 재현 조건을 PR 코멘트로 남긴 뒤 STOP한다.

## 절차

### 1. 대상 PR 확인 + CI 상태 확인

1. 대상 PR을 확정한다. 인자가 없으면 `gh pr view --json number,url,headRefName,baseRefName,state,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup,body,commits`로 현재 브랜치의 PR을 확인한다.
2. base가 의도한 기본 브랜치인지, PR이 open 상태인지, draft가 아닌지 확인한다.
3. CI와 review 상태를 확인한다. 미완료 check가 있으면 대기하거나 사용자에게 현재 상태를 보고한다. 실패 check, merge conflict, required review 미승인은 STOP한다.

Skip 조건:
- PR이 이미 merge된 상태면 squash merge 단계는 건너뛰고, 머지된 main을 최신화한 뒤 로컬 검증부터 진행한다.
- 사용자가 CI 실패를 알고도 강행하라고 한 경우에도 required gate를 우회하지 않는다. 가능한 우회가 정책상 허용되는지 먼저 보고한다.

### 2. 퀴즈 게이트 (finding-unknowns 방법론 적용 작업)

1. 이 PR이 finding-unknowns 방법론 적용 작업인지 판별한다. 1차 신호는 PR 본문의 durable marker `<!-- methodology: finding-unknowns -->`다 (기록 주체·정본: create-pr 흡수 계약 — 별도 세션에서도 남는 유일한 신호). 보조 신호는 세션·메모리 컨텍스트의 방법론 적용 선언, 워크트리에 남은 `implementation-notes.md`이며, 보조 신호만으로 판별할 때는 일반 PR 오탐에 주의한다.
2. 해당되면 머지 전에 변경의 동작 이해를 확인하는 퀴즈를 질문 도구로 출제한다 — blocking 도구 호출로 한 문항씩 답을 기다리고, plain-text로 묻고 지나가거나 답을 가정하고 진행하지 않는다. 출제 규칙의 SoT는 finding-unknowns 스킬의 `references/tactics.md` — 요지: 변경 규모에 따라 총 3~5문항을 한 문항씩 답을 기다려 순차 출제하고, 모든 문항은 PR 본문만 읽어도 답할 수 있어야 하며, 오답이면 설명 후 그 주제로 재출제한다.
3. 전 문항 정답이 통과다. 통과 전에는 squash merge를 진행하지 않는다.
4. 퀴즈 통과 직후 merge 대상을 다시 고정한다: `gh pr view --json headRefOid,body,statusCheckRollup,reviewDecision,mergeStateStatus`를 재조회하고, 퀴즈 시작 시점 대비 head 또는 본문이 바뀌었으면 바뀐 내용 기준으로 퀴즈를 다시 시작한다 (이전 head에 대한 통과로 새 head를 머지하지 않는다). 재확정한 `headRefOid`를 3단계 merge에 전달한다.

Skip 조건:
- 방법론 적용 작업이 아니면 해당 없음으로 넘어간다.
- 사용자가 명시적으로 퀴즈 스킵을 지시하면 스킵하되, 스킵 사유 한 줄을 5단계의 PR 후속 코멘트에 포함한다.
- finding-unknowns 스킬이 설치되지 않은 환경이면 위 요지만으로 출제한다.

### 3. squash merge

1. 직전에 확인한 head commit SHA를 고정해 `gh pr merge <pr> --squash --match-head-commit "$HEAD_OID"`로 squash merge한다 (확인~merge 사이에 새 push가 끼어들면 merge가 실패하도록 — 퀴즈 게이트를 거친 PR은 2단계 4항에서 재확정한 SHA를 사용한다).
2. merge 실패, 충돌, 미승인, 권한 오류가 나면 STOP하고 원문 오류를 요약해 보고한다.
3. merge 성공 후 PR 번호, URL, merge 결과 메시지, squash commit SHA를 가능한 범위에서 기록해 둔다.

Skip 조건:
- 이미 merge된 PR이면 이 단계는 건너뛴다.
- 사용자가 merge 방식 변경을 명시하지 않는 한 squash를 유지한다.

### 4. main pull + 로컬 실측 검증

1. 현재 레포 관례에 맞는 main checkout 또는 main worktree로 이동해 기본 브랜치를 최신화한다.
2. 로컬 검증 명령은 레포 컨텍스트에 위임한다. 이 레포 기본값은 main pull 후 `nrs`를 실행하고, 변경 영향 범위에 맞는 실측을 추가하는 것이다.
3. 영향 범위별 실측 예시:
   - 스킬 또는 AI 호환성 변경: 해당 스킬을 읽어 트리거/경계가 맞는지 확인하고, `./scripts/ai/check-skill-noise.sh`, 필요한 경우 `./scripts/ai/verify-ai-compat.sh`를 실행한다.
   - 서비스 또는 컨테이너 변경: 해당 서비스의 상태, 로그, 포트, healthcheck를 확인한다.
   - 에디터, shell, macOS/NixOS 설정 변경: 관련 CLI 동작 또는 설정 반영 여부를 직접 확인한다.
4. 실행한 명령, exit code, 핵심 결과를 PR 후속 코멘트용으로 기록한다.

Skip 조건:
- 문서 전용이나 주석 전용처럼 runtime 실측이 무의미한 변경은 레포의 최소 검증으로 축소하고 축소 사유를 기록한다.
- `nrs`가 명백히 불필요한 레포에서는 해당 레포의 빌드/테스트 관례를 따른다.
- 검증이 환경 제약으로 불가능하면 대체 확인을 수행하고, 불가능한 항목과 이유를 PR 코멘트에 명시한다.

### 5. PR 후속 코멘트로 검증 결과 박제

1. PR에 후속 코멘트를 남긴다. 포함 항목:
   - merge 결과와 main 최신화 여부
   - 실행한 검증 명령
   - 성공/실패 요약
   - 실패 시 원문 오류의 핵심 부분과 다음 조치
2. 검증 실패 시 코멘트를 남긴 뒤 STOP한다. 관련 이슈 close와 워크트리 정리는 하지 않는다.

Skip 조건:
- GitHub API 장애로 코멘트 게시가 실패하면 로컬에 본문을 남기고 사용자에게 재시도 명령을 보고한다.

### 6. 관련 이슈 동기화

1. PR 본문, 커밋 메시지, 브랜치명에서 참조 이슈를 수집한다.
2. `gh issue list --search`로 제목, 브랜치 키워드, 주요 변경 키워드를 검색해 누락된 관련 이슈를 확인한다.
3. 완료된 이슈는 근거 코멘트를 남긴 뒤 close한다. 부분 진행 이슈는 close하지 않고 현재 상태와 남은 작업을 코멘트로 갱신한다.
4. close 사유에는 머지된 PR 번호, 로컬 검증 결과, 완료로 판단한 근거를 포함한다.

Skip 조건:
- 관련 이슈가 없으면 없음으로 기록하고 넘어간다.
- 검증 실패, 범위 불명확, 일부 미완료가 있으면 close하지 않는다.
- 이슈가 다른 repo에 속할 수 있으면 URL 또는 repo를 재확인한 뒤 진행한다.

### 7. 산출물 위생 점검

1. 선택 단계로 머지된 diff를 훑어 코드/문서에 남은 프로세스 메타데이터, 임시 이슈 번호, 라운드 번호, finding ID, dangling partial hash, 작업용 절대경로를 확인한다.
2. 발견하면 이번 PR 후속 정리로 처리할지 별도 이슈/PR로 남길지 제안한다.

Skip 조건:
- 바이너리, lockfile, 단순 버전 핀처럼 사람이 읽는 산출물이 아닌 변경은 이 단계를 생략할 수 있다.

### 8. 워크트리 정리

1. `CLAUDE.md`의 비대화형 `wt` 규칙을 따른다.
2. 정리 대상 worktree 밖에서 실행한다 — 저장소 루트(main checkout)로 이동한 뒤 `wt cleanup`을 호출한다. worktree 안에서 실행하면 자기 자신은 삭제 대상에서 제외되어(셸의 cwd가 사라지므로) 정리되지 않는다. 4단계에서 이미 main을 최신화하며 이동했다면 그 위치를 유지하면 된다.
3. 현재 작업이 완료됐고 dirty/unpushed 변경이 없으면 `wt cleanup <name>` 또는 `wt cleanup --auto`로 정리한다.
4. dirty 또는 unpushed 상태가 있으면 STOP하고 어떤 파일/커밋 때문에 정리하지 않았는지 보고한다. 사용자 승인 없이 `--yes`로 우회하지 않는다. squash merge된 PR의 worktree는 원격 브랜치가 삭제되며 upstream이 사라져도 `wt`가 PR 상태로 보정하므로 보통 unpushed로 막히지 않는다. 다만 PR 상태 조회 뒤 그 worktree에 새 커밋이 생기면 근거가 낡아 unpushed로 되돌아가는데, 이는 잃을 커밋이 실제로 있다는 뜻이므로 정상 동작이다 — 그 커밋을 어떻게 할지 먼저 정한다.

Skip 조건:
- worktree 기반 작업이 아니면 정리할 대상이 없다고 보고하고 생략한다.
- 사용자가 보존을 요청한 worktree는 정리하지 않는다.
