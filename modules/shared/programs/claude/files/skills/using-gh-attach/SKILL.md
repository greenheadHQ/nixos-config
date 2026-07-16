---
name: using-gh-attach
description: >-
  Attach explicitly provided file evidence (screenshots, demo videos, logs) to a GitHub issue or
  PR with the gh-attach CLI — content-inspection masking gate, irreversible-upload staging,
  fail-open ATTACH_STATUS reporting. Trigger: standalone attach requests on an existing issue/PR
  ('이 스크린샷 이슈에 올려줘', 'gh attach로 첨부'), or another GitHub publishing skill reaching
  for the evidence-attachment procedure. Format/size limits delegated to the GitHub server;
  Discussions unsupported. NOT for issue/PR creation or body authoring (use create-issue/create-pr).
---

# gh-attach 시각 증빙 첨부

명시적으로 제공된 파일 증빙을 gh-attach CLI로 GitHub user-attachments에 업로드하고 이슈/PR에 삽입하는 절차다. 업로드된 asset에는 삭제 UI가 없으므로 업로드는 비가역 작업으로 취급한다.

게이트·업로드 상세의 SSOT는 [references/preflight-gates.md](references/preflight-gates.md)(사전 게이트·마스킹 게이트)와 [references/upload-and-reporting.md](references/upload-and-reporting.md)(실행기·repo 고정, 업로드·본문 삽입, `ATTACH_STATUS` 상태 보고)이며, 본문은 branch 라우팅과 안전 불변식, 단계 요약만 다룬다.

## Branch 라우팅

| 호출 문맥 | branch |
|-----------|--------|
| create-issue·create-pr 등 GitHub 게시 스킬이 본문 작성 흐름 안에서 증빙 후보를 소비 | 소비자 호출 |
| 기존 이슈/PR에 파일 첨부만 단독으로 요청받음 | 단독 호출 |

포맷·크기 지원 여부는 스킬이 선제 판정하지 않고 GitHub 서버에 위임한다 — 서버가 거부하면 fail-open 상태(`FAILED(PREUPLOAD)`)로 보고한다. 지원 범위 밖 요청은 업로드 없이 미지원 사유만 안내한다.

- Discussions는 미지원이다 — gh CLI의 discussion 본문 편집 경로가 확립되지 않았다.
- 이슈/PR 생성과 본문 작성은 이 스킬의 범위가 아니다 (create-issue/create-pr 담당).

## 안전 불변식 (모든 branch 공통)

- 첨부는 부가 기능이다. 이 절차의 검사·업로드·본문 삽입이 실패해도 본 작업(이슈/PR 게시 흐름)은 원래 본문으로 계속한다 (fail-open).
- 각 후보는 독립 상태를 갖는다. 한 후보의 탈락이나 실패 때문에 다른 후보 또는 본 작업을 차단하지 않는다.
- 업로드는 게시 의사가 확정된 뒤에만 실행한다. 모든 업로드 대상의 사전 게이트와 마스킹 게이트를 먼저 완료하며, 최종 재확인까지 모두 통과하기 전에는 어떤 파일도 업로드하지 않는다.
- 마스킹 게이트는 파일의 실제 내용을 직접 열어 검사한다. 파일명이나 사용자의 설명만으로 통과시키지 않는다.
- 직접 검사 수단이 없는 파일(동영상 등)은 업로드 직전 사용자의 별도 명시 확인 1회 없이 업로드하지 않는다 — 첨부 요청 자체는 확인으로 간주하지 않는다. 검사 수단이 있는 파일은 검사 없이 사용자 확인으로 넘기지 않는다.
- `href` 확보 후의 실패는 확보한 `href`를 재사용한다. 자동 재업로드하지 않는다.
- 후보가 없으면 이 절차를 실행하지 않고 `ATTACH_STATUS`도 출력하지 않는다.

## 소비자 호출 branch

호출 스킬이 후보 목록, 본문 사본, 삽입 슬롯, 게시 게이트를 제공한다.

1. 본문 작성 단계에서는 후보를 식별하고 삽입 슬롯만 준비한다. 슬롯 위치 규칙 — 이슈: issue-template의 `시각적 실제 결과` 절. PR: 데모·터미널 증빙은 구현 상세 절 말미, before/after 검증 이미지는 Human Test Plan의 해당 단계 아래.
2. 업로드는 게시 의사가 확정된 뒤, `--body-file` 게시 직전에만 실행한다. 사용자 확인 게이트가 있으면 확인 통과 전에는 업로드하지 않는다.
3. 모든 후보에 [references/preflight-gates.md](references/preflight-gates.md)의 사전 게이트와 마스킹 게이트를 완료한다.
4. [references/upload-and-reporting.md](references/upload-and-reporting.md)의 실행기·repo 고정, 업로드, 본문 삽입을 수행하고 `ATTACH_STATUS`를 호출 스킬의 최종 응답에 포함한다.
5. `create-pr update`에서는 기존 `user-attachments` 링크를 그대로 보존한다. 명시적으로 새로 제공된 후보만 검사하며 기존 링크나 동일 파일을 재업로드하지 않는다.

## 단독 호출 branch

1. 대상 확정과 repo 고정: 첨부할 이슈 또는 PR의 URL·번호를 확인한다. URL이면 URL에서 `OWNER_REPO`와 번호를 추출하고, 번호만 받았으면 현재 작업 디렉터리의 canonical repo(`gh repo view --json nameWithOwner -q .nameWithOwner`)를 `OWNER_REPO`로 사용한다. 추출한 repo가 현재 작업 디렉터리의 canonical repo와 다르면 진행하지 않고 거부한다 — cross-repo 첨부는 미지원이다 (업로드 asset의 접근 경계가 `-R` 지정 repo에 묶이므로, 대상 불일치는 잘못된 본문 조회·엉뚱한 저장소 게시로 이어진다). 대상이 불명확하면 진행 전에 확인을 요청한다. 이후 모든 조회·게시 명령에 같은 `-R "$OWNER_REPO"`를 명시한다.
2. 기존 본문 조회·보존: surface별로 현재 본문을 조회해 보존한다 — 이슈는 `gh issue view <N> -R "$OWNER_REPO" --json body`, PR은 `gh pr view <N> -R "$OWNER_REPO" --json body`.
3. 삽입 방식 선택: 본문(body) 수정과 comment 추가 중 하나를 정한다. 사용자가 지정하지 않았으면 기존 본문 훼손 위험이 없는 comment 추가를 권한다.
4. 게시 의사 확정: 비가역 업로드 전에 대상, 삽입 방식, 게시 여부를 확정한다. 확정 전에는 업로드하지 않는다.
5. 게이트·업로드: [references/preflight-gates.md](references/preflight-gates.md)의 게이트를 완료한 뒤 [references/upload-and-reporting.md](references/upload-and-reporting.md)의 절차로 업로드한다.
6. 게시: body 수정이면 보존한 본문 사본에 파일 종류별 삽입 문법([references/upload-and-reporting.md](references/upload-and-reporting.md) 4절 — 이미지는 `![<설명>](<href>)`, 동영상은 단독 라인 bare URL, 그 외는 `[<파일명>](<href>)` 링크)으로 삽입해 `--body-file`로 게시하고, comment면 comment 본문으로 게시한다. `href` 확보 후 삽입·검증이 실패하면 게시하지 않고 `FAILED(LOCAL_INSERT)`와 확보한 `href`만 보고한다 — 기존 본문은 서버에 그대로 있으므로 보존해 둔 사본을 재게시하지 않는다. 게시 자체가 실패하면 확보한 `href`와 본문 파일을 보존해 동일 asset으로 재시도한다 — 새 asset을 업로드하지 않는다.
7. 최종 응답에 후보별 상태와 `ATTACH_STATUS`를 포함한다.
