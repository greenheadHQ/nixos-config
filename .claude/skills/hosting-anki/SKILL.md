---
name: hosting-anki
description: |
  Manage the MiniPC headless Anki host, AnkiWeb sync, backups, private Anki MCP connector and safe Mac Anki GUI automation.
  Use for Anki MCP errors, host sync status, operation receipts, restore points or root-approved note-type changes.
  Personal card content and study rules belong to the user's study project.
---

# Hosting Anki

운영 계약과 API 지원표의 정본은 [Anki 호스트 README](../../../modules/nixos/programs/anki-host/README.md)다.
장애·미리보기·복구·노트 타입 변경을 다룰 때 해당 절을 읽고 소스와 실제 배포 버전을 대조한다.
과거 도입 기록의 무인증 호출 예시는 현재 인증 배선에 사용하지 않는다.

## 먼저 확인할 것

- `anki_status`와 `anki_operation_status`/`anki_recent_operations`에서 적용·동기화·알림 상태를 따로 확인한다.
- 대상은 MiniPC `main`인지 격리 `lab`인지 명시한다. Mac의 loopback AnkiConnect와 혼동하지 않는다.
- 배포 버전·서비스 상태는 실측한다. 소스에 도구가 있다는 사실만으로 운영 배포를 완료했다고 하지 않는다.

## Mac GUI 자동화 안전 경계

- Computer History 관찰 설정에서 Anki(`net.ankiweb.anki`)를 항상 제외한다. 이 제외는 명시적인 Computer Use까지 막지 않는다.
- Computer Use는 일반 덱 선택·복습·동기화 화면과 iPhone Mirroring에서 사용할 수 있다. 다만 독립·내장 편집 창 또는
  선택 행이 있는 `탐색` 창을 Computer Use로 열거나 그 안에서 조회·클릭·키 입력·스크롤 등 어떤 조작도 하지 않는다.
  격리 임시 프로필 A/B 검증 전에는 MCP/API나 사용자 수동 조작을 사용하고, 위험 창을 닫은 뒤 Computer Use를 재개한다.
- 자세한 충돌 근거와 재검증 경계는 README의 같은 절을 따른다.

## 변경·재개 판단

- 변경 전 검색·상세 조회로 ID를 정한다. 같은 논리적 변경은 같은 `request_id`를 사용한다.
- 이 환경의 검토 대기열은 사용자와 합의한 별표(`marked`)다. `tag:marked` 검색의 모든 페이지를 모으고,
  요청한 검토 작업과 결과 확인을 마친 노트를 모아 결과를 보고한 뒤 정리 방식을 한 번 묻는다:
  별표·메모 모두 지우기 / 별표만 해제하고 메모 보관 / 둘 다 유지. 답변 전에는 둘 다 유지한다.
  Codex에서는 현재 세션에 제공된 `request_user_input` 또는 `request_user_input_async` 중
  이 확인에 사용하도록 허용된 질문 도구로 묻는다. 사용할 수 있는 질문 도구가 없으면 대화로 묻는다.
  메모 보관 필요에 맞는 추천과 이유를 함께 제시한다.
  같은 대상과 정리 방식을 이미 명시적으로 승인했으면 재질문하지 않는다. 단순 목록·조회는 완료가 아니다.
  형제 카드까지 포함해 미완료 작업·메모의 미해결 질문이 남은 노트는 제외한다.
  정리 직전 전체 메모를 다시 읽고 제안 이후 바뀌었으면 보존하고 다시 확인한다.
  승인된 노트의 기존 `검토 메모` 값과 `marked`만 선택대로 정리하며, 다른 필드·태그·깃발·일정은 유지한다.
  단일·일괄 필드 수정으로 메모를 비울 때 각 노트의 `expected_fields`에 마지막으로 읽은 전체 메모 값을
  HTML·줄바꿈까지 그대로 넣는다. `expected-field-value-mismatch`이면 메모·별표를 유지하고 새 내용을 읽어
  다시 확인받는다. 기대값 검사를 빼거나 새 값으로 대체해 자동 재시도하지 않는다.
  둘 다 지울 때는 메모를 비우고 확인한 뒤 별표를 해제한다. 일부 실패·결과 불명은 상태를 확인해 보고한다.
  깃발의 색을 검토 대기열로 간주하지 않는다.
  별도 깃발 검색은 `flag:N`, 설정·변경·해제는 `anki_set_card_flags`(0 해제)를 쓴다.
  `검토 메모`가 있으면 `anki_note_info`로 여러 문단을 포함한 전체를 읽고, 표시 해제만으로 메모를 지우지 않는다.
  메모 필드는 노트 단위이며 새 타입에는 자동 추가되지 않는다. 준비와 호환성 확인은 README의 검토 메모 절을 따른다.
  메모에는 빈칸 생성 구문을 그대로 넣지 않고 `c1: 정답`처럼 풀어 적는다. Cloze·이미지 가리기는 숨긴 메모에서도
  해당 구문으로 카드를 추가한다. 이 규칙은 자동 차단이 아니며 기존 메모를 임의로 고치는 근거도 아니다.
- 파괴·일정·잊기·20건 초과·공유 프리셋 변경은 반환된 preview 전체 영향과 경고를 사용자에게 보여 주고,
  그 대상에 대한 확인 후 같은 인자·ID·토큰과 `confirm=true`로 실행한다. 요청 자체가 이미 정확한 변경을
  승인했는지 판단하되, 서버의 preview 토큰 절차를 건너뛰지는 않는다.
- `partial`/`unknown`을 새 ID로 전체 반복하지 않는다. 로컬 적용 완료 뒤 sync 실패는 변경 재실행과 구분한다.
- 노트 타입 구조 변경은 MCP가 준비만 한다. root 명령은 사용자에게 승인받은 특정 변경·Upload 범위에서만 실행한다.
  구조 변경이 `applied`이면 같은 operation ID에 새 root 승인을 발급해 동기화만 재개한다.
  이미 승인한 실행을 반복 확인할 필요는 없지만, `FULL_DOWNLOAD`·카운트 감소·결과 불명은 자동 재개하지 않는다.
- 미디어는 base64 신규 파일 추가만 지원한다. 복구점은 미디어 제외이므로 덮어쓰기·삭제로 범위를 넓히지 않는다.

## 호스트 조사

서비스는 `anki-host-main`, `anki-mcp`, `anki-host-sync-main`, `anki-host-backup`이다.
상태 원본은 `/var/lib/anki-host/main/sync-status.json`, MCP 사본은 `/run/anki-host-status/main.json`이다.
배선은 `modules/nixos/programs/anki-host/`·`anki-mcp/`, 값은 `libraries/constants.nix`를 확인한다.
키는 root 전용 runtime 파일에서 `LoadCredential`로 전달한다. 키·준비 중 카드 본문·미디어를 출력하지 않는다.
일반 sync가 막히면 먼저 영수증과 서비스 로그를 조사하고 `sync-status.json` 삭제로 급감 게이트를 해제하지 않는다.

운영 적용은 `nrs` 경로를 따른다. 검증은 README의 격리 테스트와 배포 후 lab/main 확인을 구분해 보고한다.
Plugin Lab 등록 제거는 MiniPC lab 컬렉션 폐기 승인이 아니다.
