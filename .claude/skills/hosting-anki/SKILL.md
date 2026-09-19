---
name: hosting-anki
description: |
  Manage the MiniPC headless Anki host, AnkiWeb sync, backups and private Anki MCP connector.
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

## 변경·재개 판단

- 변경 전 검색·상세 조회로 ID를 정한다. 같은 논리적 변경은 같은 `request_id`를 사용한다.
- 검토 표시의 종류·색은 사용자와 정한다. 깃발 검색은 `flag:N`, 설정·변경·해제는 `anki_set_card_flags`(0 해제)를 쓴다.
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
