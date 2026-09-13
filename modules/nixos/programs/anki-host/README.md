# Anki 호스트와 MCP 운영 계약

이 문서는 Anki 호스트와 MCP 소스의 운영 계약이다. **구현·격리 검증과 운영 배포 여부는 별도 확인한다.**
도입 이력은 [이슈 #1306](https://github.com/greenheadHQ/nixos-config/issues/1306), 실기기·장애 검증은 [PR #1317](https://github.com/greenheadHQ/nixos-config/pull/1317), iPhone 직접 추가 검증은 [PR #1320](https://github.com/greenheadHQ/nixos-config/pull/1320)에 남긴다.
개인 학습 방식·카드 내용 규칙은 이 인프라에서 정하지 않는다.

## 변경 요청과 결과 확인

1. `anki_status`, 검색·상세 조회로 현재 대상과 ID를 확인한다.
2. 논리적 변경마다 8–128자의 `request_id`를 정한다(영문·숫자·`_`·`-`, 첫 글자는 영문·숫자).
3. 변경 도구를 호출한다. 일반 동기화의 **새 회차 성공** 뒤 준비하며, 작은 변경은 바로 실행된다.
4. 삭제·일정·잊기·20건 초과·공유 프리셋 변경은 미리보기만 돌려준다. 영향 수·경고를 사용자에게 보여 준 뒤,
   확인받은 **같은 인자·request_id·preview_token**에 `confirm=true`를 넣어 호출한다.
5. 결과의 적용 상태와 동기화·알림 상태를 각각 확인하고 대상 노트·카드를 다시 조회한다.

20건은 입력 배열 길이가 아니라 고유 노트 수·영향 카드 수·추가 노트 수 중 최댓값이다. 20까지는 작은 변경,
21부터는 대량 변경이다. 한 노트의 cloze 21장도 대량이다. 토큰은 10분 뒤 만료된다.
대상이 바뀌면 `stale-preview`로 거부하며 새 ID로 다시 미리보기와 확인을 진행한다.

기존 변경 도구의 이름과 필수 업무 인자는 유지하지만, 반환값은 작업 영수증으로 확장했다.
예전 `added`, `results`, `deck_id` 같은 업무 결과는 `result` 아래에서 읽는다.

```json
{
  "operation_id": "<32자리 hex>",
  "request_id": "cards-review-001",
  "state": "applied",
  "result": {"added": 1, "results": [{"noteId": 123, "error": null}]},
  "sync": {"state": "synced"},
  "notification": {"state": "sent"}
}
```

| 상태 | 의미와 후속 행동 |
|---|---|
| `prepared` | 아직 변경하지 않았다. 영향·확인 토큰 또는 root 승인 안내를 검토한다. |
| `applied` | 로컬 변경 완료. `sync`가 미완료면 같은 원 요청을 재호출해 전달만 재개한다. |
| `partial` | 입력 중 일부만 성공하거나 일부 결과가 불명이다. 입력별 ID·오류를 확인하고 새 ID로 전체를 반복하지 않는다. |
| `unknown` | 적용 진행 중·응답 유실·프로세스 종료 등으로 결과를 확정할 수 없다. 상태·실제 카드·복구점을 조사한다. 자동 재적용 금지. |
| `expired` | 확인 기간이 지났다. 새 미리보기와 사용자 확인이 필요하다. |

`anki_operation_status(operation_id)`와 `anki_recent_operations`로 작업을 찾는다.
ID 없이 보낸 요청의 응답을 잃었으면 최근 작업부터 확인한다. `notification=unknown`은 알림 전달 여부 불명이며
자동 재발송하지 않는다. 원장은 종료 시 본문·미디어·확인 토큰을 지우고 결과와 재사용 방지 기록을 보존한다.
미완료 본문도 만료 정리 시 제거한다. 원장과 복구점에는 별도의 삭제 정책을 적용한다.
원장 내부의 `applying`도 공개 조회에서는 `unknown`으로 반환되므로 실행 완료로 해석하지 않는다.

일반 동기화는 백그라운드 미디어 전송의 완료·오류도 확인한 뒤 성공으로 기록한다. 미디어 저장 작업은
`sync.media_state=synced`까지 확인해야 전달 완료다. 미디어 설정이 꺼져 있거나 결과를 확인하지 못하면
`sync.state=pending`을 유지한다. 같은 요청으로 다시 호출하면 파일을 재저장하지 않고 동기화만 재개한다.
컬렉션과 전후 미디어 대기는 기존 변경 작업 예산 30분을 공유한다. 별도의 미디어 대기 시간을 더하지 않는다.
시간 초과 시 성공 기준점을 갱신하지 않으며, 아직 실행 중인 callback의 lock은 완료될 때까지 유지한다.
MCP의 결과 대기는 별도 3분이므로 호출이 먼저 끝날 수 있다. 이 경우 같은 요청 ID의 전달 상태를 다시 확인한다.

## 지원표

소스 핀: Anki **26.08**, AnkiConnect **25.11.9.0**, helper **2.0.0**, MCP SDK **1.29.0**.
Anki 본체를 별도 overlay로 다시 만들지 않고, AnkiConnect 애드온에만 인증·내부 호출 연결 패치를 적용한다.
핀 변경 시 아래 실제 API 테스트를 다시 실행한다.

| MCP 도구 | 실제 API / 주의점 |
|---|---|
| `anki_add_notes`, `anki_update_note_fields` | `canAddNotesWithErrorDetail`, `addNotes`, `updateNoteFields`; 추가는 `mcp::added`, 입력별 결과. 필드 변경은 새 카드 생성 가능. |
| `anki_add_tags`, `anki_remove_tags`, `anki_create_deck` | `addTags`, `removeTags`, `createDeck`; 공통 변경 원장 적용. |
| `anki_move_cards` | `changeDeck`; 존재하는 일반 덱으로 이동. 대상 카드 수에 따라 확인. |
| `anki_delete_notes` | `deleteNotes`; 해당 노트의 모든 카드에 영향, 항상 확인·복구점. |
| `anki_delete_decks` | `deleteDecks(cardsToo=True)`; 하위 덱 포함. 다른 덱의 형제 카드는 유지, 고아 노트는 삭제. filtered/default 덱 경고는 preview에서 확인. |
| `anki_suspend_cards` | `suspend` + `areSuspended` readback; 정지와 해제 모두 지원. |
| `anki_set_due_date` | `setDueDate`; `2`, `2-5`, `2!` 문법. 범위는 무작위, 수동 복습 기록 추가·정지 해제 가능. |
| `anki_forget_cards` | `forgetCards`; 새 카드 학습 상태로 돌아가며 과거 복습 기록 전체를 지우지 않는다. |
| `anki_store_media`, `anki_media` | base64 신규 저장·이름 목록/조회. decoded 5 MiB, 안전한 NFC 파일명. 같은 내용은 no-op, 다른 내용의 덮어쓰기·삭제·URL/path 입력은 없음. |
| `anki_deck_options`, `anki_update_deck_options` | `getDeckConfig`, `saveDeckConfig`; 현재 프리셋 ID 고정, 공유 덱 목록 표시. 아래 허용 값만 patch. |
| `anki_model_info`, `anki_prepare_model_change` | 필드 add/remove/rename/reposition, 템플릿 add/remove/update. 준비만 수행하고 root 승인 경로에서 적용. |
| `anki_update_model_css` | `updateModelStyling`; 빈 CSS도 지원, 구조 변경과 별도. |
| `anki_sync_now` | 기존 normal systemd 서비스 실행. 전체 동기화 방향 선택 인자 없음. |

덱 옵션 허용 키는 adapter의 `OPTION_RANGES`가 정본이다:
`new.perDay`, `new.order`, `new.initialFactor`, `rev.perDay`, `rev.maxIvl`, `rev.ease4`,
`rev.ivlFct`, `rev.hardFactor`, `lapse.mult`, `lapse.minInt`, `lapse.leechFails`, `lapse.leechAction`.
현 버전에서 없는 키·범위 밖 값·프리셋 ID/name 교체는 거부한다. FSRS 설정 전체 편집은 지원하지 않는다.

## 권한과 동시 실행

- root 키 생성 서비스가 인스턴스별 read/operation/maintenance/schema 키를
  `/var/lib/anki-host-credentials/<instance>/`에 만든다. root 0700, 키 0600. 재시작 때 회전하지 않는다.
- systemd `LoadCredential`로 Anki에는 네 키, MCP에는 read/operation, sync·backup에는 maintenance,
  root 승인 서비스에는 schema만 전달한다. 값은 Nix store·명령 인자·로그에 남기지 않는다.
- AnkiConnect HTTP는 인증된 조회 allowlist만 허용한다. raw write·sync·`multi`·GUI는 거부한다.
  helper의 `/status`를 포함한 모든 route에도 역할 키가 필요하다. 옛 무인증 curl 명령은 더 이상 유효하지 않다.
- helper의 동일 lock과 메인 스레드 안에서 대상 재확인 → 복구점 → 변경을 수행한다.
  HTTP 타임아웃 뒤에도 callback이 끝날 때까지 lock을 유지한다.
- helper가 프로필을 열 때 GUI의 시작·종료 자동 동기화와 주기적 미디어 동기화를 끈다. 기존 프로필에도 적용한다.
  systemd 일반 동기화가 미디어 전달을 함께 담당하며, 이미 GUI 미디어 감시가 실행 중이면 해당 sync를 거부한다.
- MCP는 컬렉션 디렉터리(0700)에 직접 접근하지 않는다. normal sync start 외 systemd 실행 권한을 받지 않는다.
  원본 상태는 `anki-host:anki-host` 0600, `/run/anki-host-status/main.json` 사본은 0640이다.
- 일반 동기화의 급감 게이트는 유지한다. 정당한 대량 삭제로 게이트가 걸려도 MCP가 기준값을 초기화하지 않는다.

## 구조 변경과 승인 Upload

`anki_prepare_model_change`의 preview에서 필드/템플릿, 영향 수, 복구점·전체 동기화 필요성을 확인한다.
실제 변경과 AnkiWeb Upload를 승인한 운영자가 MiniPC에서 다음 명령을 실행한다.

```bash
sudo anki-host-approve-main <operation_id> --confirm
```

준비 상태는 새 normal 사전 동기화 → 대상 재확인 → 복구점/HDD 검증 → root 승인 파일 생성 순서다.
승인은 인스턴스·작업·전체 컬렉션 스냅샷·직전 성공 카운트·복구점 hash·만료에 묶여 한 번 소비된다.
MCP는 schema 키나 승인 파일 생성·서비스 시작 권한을 갖지 않는다.

root 서비스도 일반 sync와 같은 lock을 쓴다. 로컬 노트·카드가 비어 있거나 노트/복습 기록이 줄면 Upload를 막는다.
Anki가 `FULL_SYNC`/`FULL_UPLOAD`를 요구할 때만 Upload하고 `FULL_DOWNLOAD`는 차단한다.
구조 변경은 성공했어도 Upload가 실패할 수 있다. `applied + sync=blocked`이면 내용을 검토한 뒤 같은 operation ID에
새 root 승인을 발급해 전달만 재개한다. `unknown`은 이 자동 재개 경로에도 들어가지 못한다.
CLI 종료 코드와 출력된 operation 상태를 함께 확인한다. 명령 실패만으로 로컬 변경이 없었다고 판단하지 않는다.

## 복구점과 장애 조사

작업 복구점은 **미디어 제외** `.colpkg`다. SSD `<state>/restore-points/<operation_id>.colpkg`를
root 서비스가 HDD `/mnt/data/backups/anki-host-restore-points/<instance>/`로 복사한다.
ZIP CRC·SHA256·디렉터리 fsync 완료 후 receipt를 쓰고, 그 뒤에만 변경한다.
SSD는 최신 5개(현재 작업 포함), HDD는 무기한이다. HDD와 hash가 같은 SSD 사본만 정리한다.
기존 파일 덮어쓰기·심볼릭 링크 입력은 거부한다. 일일 미디어 포함 백업은 기존 별도 타이머를 유지한다.

조회 시작점:

```bash
systemctl status anki-host-main anki-mcp anki-host-sync-main
sudo cat /var/lib/anki-host/main/sync-status.json
sudo journalctl -u 'anki-host-schema-main@*' -u 'anki-host-mirror-main@*' --since today
```

작업 원장: `/var/lib/anki-host/main/operations/`. 본문이 있는 준비 파일을 출력하거나 외부에 붙여 넣지 말고
MCP의 상태/최근 작업 응답을 우선 사용한다. 로그에 키·본문이 나타나면 노출 경로를 먼저 조사한다.
복구는 백업을 임시 프로필에 가져와 ID·카운트·내용을 확인한 다음 대상 교체와 동기화 방향을 별도로 승인한다.
복구점 이름을 기존 운영 프로필에 바로 import하지 않는다. AnkiWeb에 연결된 main에는 helper import route가 없다.
다른 기기에 아직 동기화하지 않은 학습은 이 호스트가 알 수 없으며 자동 rollback도 제공하지 않는다.

## 검증과 배포

- `nix develop --command bash tests/run-anki-mcp-tests.sh`: 원장·확인·역할 인증·sync/알림·root 미러/승인·셸 상태 기록의 격리 테스트.
- `nix develop --command bash tests/run-eval-tests.sh`: 일반/no-IFD 모듈·권한·상수 배선 검사.
- `tests/anki-runtime/test_real_collection.py`: Anki/aqt 26.8 환경에서 `ANKICONNECT_SOURCE`를 실제 빌드한 애드온 디렉터리로
  지정해 pytest 실행. 합성 임시 컬렉션과 실제 AnkiConnect/Rust backend를 사용한다. GUI 콜백은 대체하고 포트·계정은 열지 않는다.
- root→일반 sync 셸 fixture는 실제 JSON/파일/lock과 chown 호출을 검사하지만 실제 Linux UID 전환을 대신하지 않는다.
- 배포 시 `nrs`를 사용한다. 새 로컬 키가 필요한 모든 consumer가 함께 전환돼야 한다.
  lab 합성 데이터로 생성·이동·일정·삭제·복구점/HDD·재시작 후 중복 방지를 확인한 뒤 main에서 읽기와 허가받은 작은 변경을 확인한다.
- 스킬 투영 변경 후 `nrs`와 `./scripts/ai/verify-ai-compat.sh`의 런타임 검증을 완료한다.
  임시 실컬렉션 테스트는 AnkiWeb Upload나 iPhone ChatGPT→AnkiMobile 경로 검증을 대신하지 않는다.
- 옛 **Anki Plugin Lab 등록 제거**와 MiniPC `lab` 데이터/서비스 폐기는 다른 작업이다. 2026-09-11 운영자는 향후 시험을 위해 lab 유지를 선택했다. 미로그인·sync 비활성 경계를 유지하고, 삭제는 향후 별도 결정 후 처리한다.
