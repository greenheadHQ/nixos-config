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
핀 변경 시 아래 실제 API 테스트를 다시 실행한다. nixpkgs 쪽 세 값의 재검증(helper는 `addons.nix`의 `version`):

```bash
nix eval --raw --impure --expr 'let p = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
  in "anki=${p.anki.version} anki-connect=${p.ankiAddons.anki-connect.version} mcp=${p.python3Packages.mcp.version}"'
```

| MCP 도구 | 실제 API / 주의점 |
|---|---|
| `anki_add_notes`, `anki_update_note_fields` | `canAddNotesWithErrorDetail`, `addNotes`, `updateNoteFields`; 추가는 `mcp::added`, 입력별 결과. 필드 변경은 새 카드 생성 가능. |
| `anki_add_tags`, `anki_remove_tags`, `anki_create_deck` | `addTags`, `removeTags`, `createDeck`; 공통 변경 원장 적용. |
| `anki_move_cards` | `changeDeck`; 존재하는 일반 덱으로 이동. 대상 카드 수에 따라 확인. |
| `anki_delete_notes` | `deleteNotes`; 해당 노트의 모든 카드에 영향, 항상 확인·복구점. |
| `anki_delete_decks` | `deleteDecks(cardsToo=True)`; 하위 덱 포함. 다른 덱의 형제 카드는 유지, 고아 노트는 삭제. filtered/default 덱 경고는 preview에서 확인. |
| `anki_suspend_cards` | `suspend` + `areSuspended` readback; 정지와 해제 모두 지원. |
| `anki_find_cards`, `anki_set_card_flags` | `flag:N` 검색과 응답 `flag`(0–7, 조회 불가 시 null). 설정은 Anki `set_user_flag_for_cards` + readback; 1–7 설정/변경, 0 해제. 지정 카드만 변경하며 노트·형제 카드·일정·복습 기록을 보존. 20건 초과 확인·복구점 적용. |
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

## 검토 표시와 메모

이 개인용 환경의 검토 대기열은 사용자 결정에 따라 **별표**를 사용한다.
별표는 노트의 `marked` 태그이며, `anki_find_notes(query="tag:marked")`의 모든 페이지를 모은 뒤
`anki_note_info`로 검토 메모와 본문 전체를 읽는다. 검토가 끝난 노트는 `anki_remove_tags`로
`marked`만 해제하고 메모는 유지한다. 같은 노트에서 나온 여러 카드는 함께 검토한다.
깃발은 카드 단위이며 `anki_find_cards(query="flag:N")`으로 모으고 `anki_set_card_flags(..., flag=0)`으로 해제한다.
깃발은 별도로 사용할 수 있지만 특정 색을 검토 대기열로 해석하지 않는다.

질문 이유·수정 방향은 선택적인 **`검토 메모` 필드**에 남긴다. 한 줄 제한 없이 여러 문단·질문·예시를 저장하며,
기존 설명·Extra·Comments 필드와 섞지 않는다. 이 필드는 노트 단위로, 같은 노트의 역방향·여러 빈칸 카드가 공유한다.
특정 카드만의 질문은 방향·빈칸을 메모에서 구분한다.

- 준비: `anki_models`/`anki_model_info`로 필드 존재와 템플릿 참조를 확인한다. 없는 타입에만
  `anki_prepare_model_change(action="model_field_add", params={"model_name": "...", "field_name": "검토 메모"})`로
  끝에 필드를 추가하는 미리보기를 만든다. 기존 필드를 덮어쓰거나 형식을 바꾸지 않는다.
  아래 구조 변경 승인·복구점 경로로 실행하며, 문제·정답 템플릿에는 메모 필드를 넣지 않는다.
- 적용 범위: 준비된 타입의 기존 노트와 이후 생성 노트에 같은 입력칸이 생긴다.
  새 타입·외부 덱에서 가져온 타입에는 자동 추가되지 않는다. 누락을 확인하고 같은 준비 절차를 거친다.
  이미지 가리기·제3자 편집기/템플릿은 해당 클라이언트에서 별도 확인한다.
- 입력: AnkiMobile 복습 중 편집 화면에서 메모를 쓰고 저장한다. 입력 동선과 단락 표시의 실제 동작은
  기기·노트 타입별로 확인한다. 표시만 남기기는 빠르지만 메모 입력까지 한두 번 탭을 보장하지 않는다.
  **메모에 Anki 빈칸 생성 구문(`{{c1::정답}}` 등)을 그대로 붙여넣지 않는다.**
  `c1: 정답`처럼 풀어 적거나 일반 문장으로 설명한다. Cloze·이미지 가리기에서는 Anki가
  템플릿에서 참조하지 않는 메모 필드까지 검사해 실제 카드를 추가한다. 필드를 숨겨도 막히지 않는다.
  이는 입력 규칙이며 자동 차단 기능이 아니다. HTML entity 표현도 모바일 재편집까지의 보장을 대신하지 않는다.
- 조회: 검색 응답은 필드당 기본 400자로 잘릴 수 있으므로, 검토 전에 `anki_note_info`의
  기본 전체 조회로 **메모 전체**를 읽는다. HTML 문단/줄바꿈을 보존하고, 표시 해제만으로 메모를 지우거나 다시 쓰지 않는다.
  모바일과 호스트의 AnkiWeb 동기화가 모두 끝나야 모바일 메모가 호스트 조회에 반영된다.
- 검증: 필드 준비·메모 편집 전후 기존 필드, 카드 ID/수, 일정, 복습 기록, 템플릿/렌더링을 대조한다.
  일반 장문·여러 문단의 보존과, 빈칸 생성 구문을 그대로 쓰면 카드가 추가되는 제한을 각각 실엔진에서 검증한다.
  메모 수정 중 예상 카드 수가 늘면 구문을 확인하고, 확인·복구점 절차를 생략하지 않는다.

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

### 이전 필드 값만 회수하기

단일·일괄 필드 수정은 건수와 관계없이 변경 직전 미디어 제외 복구점을 만들고 HDD 사본까지 검증한다.
20건 이하의 필드 수정에 복구점을 만든다는 이유만으로 추가 확인을 요구하지는 않는다.
원장에는 변경 전후 본문을 남기지 않는다. 기존 복구점 보존 정책(SSD 최신 5개, HDD 무기한)을 유지하며,
작업마다 컬렉션 크기에 비례하는 HDD 사본이 하나 늘어난다(현재 규모의 실측은 약 1.4MB/작업).

`anki_operation_status`의 `backup`으로 해당 수정 **직전** 복구점을 선택한다. 이전 작업이나 플러그인 밖에서
수정한 내용에는 아래 두 종류의 백업도 사용할 수 있지만, 그 백업 이후·다음 백업 이전의 중간 값은 보장하지 않는다.

| 백업 | 위치·보존 |
|---|---|
| Anki 자체 자동 백업 | `<state>/<instance>/Anki2/<instance>/backups/`. Anki가 5분마다 생성 여부를 확인하고 컬렉션의 `get_preferences().backups` 간격·일/주/월 정책을 적용한다. `prefs21.db`의 구형 `numBackups` 값은 26.08에서 이 정책을 정하지 않는다. |
| 일일 미디어 포함 백업 | `<state>/<instance>/backups/` 최신 2개, HDD `<mediaData>/backups/anki-host/<instance>/` 기본 14일. 기본 04:15에 최대 5분 지연을 더해 생성한다. |

2026-09-19 운영 백업 사본에서 확인한 자체 백업 설정은 최소 10분, 일/주/월 각각 30개였다.
이는 고정 10분 주기나 최근 30개라는 뜻이 아니다. 변경된 컬렉션만 백업하며 오늘·어제의 사본은 모두 유지하고,
그보다 오래된 서로 다른 날짜·주·월의 대표 사본을 순차적으로 남긴다. 실제 설정은 이후 변경될 수 있다.
상세 알고리즘은 [Anki 26.08 백업 구현](https://github.com/ankitects/anki/blob/26.08/rslib/src/collection/backup.rs)을 따른다.

필드 회수 명령은 MiniPC의 root 전용 `anki-host-recover-fields`다. 입력은 해당 인스턴스의 위 백업 또는
복구점 디렉터리 바로 아래 `.colpkg`만 허용하며, 라이브 DB·심볼릭 링크를 거부한다. 예시의 경로·ID는 실제 대상으로 바꾼다.

```bash
sudo install -d -m 0700 /root/anki-field-recovery
sudo anki-host-recover-fields --instance main \
  --backup /mnt/data/backups/anki-host-restore-points/main/OPERATION_ID.colpkg \
  --note-id NOTE_ID --output /root/anki-field-recovery/selected-fields.json
```

여러 노트는 `--note-id`를 반복한다(중복 없이 최대 100개). 출력 디렉터리는 root 소유이고 다른 사용자에게
권한이 없어야 하며, 기존 출력 파일은 덮어쓰지 않는다. 성공 stdout에는 건수와 백업 hash만 나오고,
0600 JSON 파일에 선택한 노트의 ID·GUID·당시 노트 타입·필드 이름과 원문이 저장된다. 이 파일을 로그·이슈·PR에
붙이지 않는다. 필요한 원문을 확인한 뒤 사용이 끝난 비공개 추출 파일은 운영자가 정리한다.

명령은 네트워크가 분리된 프로세스에서 공식 Anki importer로 **0700 임시 사본만** 열고 자동 폐기한다.
신규 패키지의 실제 DB는 `collection.anki21b`이고 `collection.anki2`는 더미일 수 있으므로 직접 골라 읽지 않는다.
운영 컬렉션·AnkiWeb·원장에는 쓰지 않고 MCP 서비스의 파일 접근 권한도 늘리지 않는다.
회수된 값은 **자동 적용하지 않는다**. 현재 노트의 GUID·타입·필드 이름과 비교해 사용자가 되돌릴 필드를 선택한 뒤
기존 MCP 필드 수정 경로로 적용한다. 노트나 필드가 삭제·이름 변경된 경우에는 그 차이를 먼저 검토하며,
예전 필드 순서로 현재 노트에 덮어쓰거나 운영 프로필 전체를 가져오지 않는다.

## 검증과 배포

- `nix develop --command bash tests/run-anki-mcp-tests.sh`: 원장·확인·역할 인증·sync/알림·root 미러/승인·셸 상태 기록의 격리 테스트.
- `nix develop --command bash tests/run-eval-tests.sh`: 일반/no-IFD 모듈·권한·상수 배선 검사.
- `tests/anki-runtime/`: Anki/aqt 26.8 환경에서 `ANKICONNECT_SOURCE`를 실제 빌드한 애드온 디렉터리로
  지정해 pytest 실행. 합성 임시 컬렉션과 실제 AnkiConnect/Rust backend를 사용한다. GUI 콜백은 대체하고 포트·계정은 열지 않는다.
- root→일반 sync 셸 fixture는 실제 JSON/파일/lock과 chown 호출을 검사하지만 실제 Linux UID 전환을 대신하지 않는다.
- 배포 시 `nrs`를 사용한다. 새 로컬 키가 필요한 모든 consumer가 함께 전환돼야 한다.
  lab 합성 데이터로 생성·이동·일정·삭제·복구점/HDD·재시작 후 중복 방지를 확인한 뒤 main에서 읽기와 허가받은 작은 변경을 확인한다.
- 스킬 투영 변경 후 `nrs`와 `./scripts/ai/verify-ai-compat.sh`의 런타임 검증을 완료한다.
  임시 실컬렉션 테스트는 AnkiWeb Upload나 iPhone ChatGPT→AnkiMobile 경로 검증을 대신하지 않는다.
- 옛 **Anki Plugin Lab 등록 제거**와 MiniPC `lab` 데이터/서비스 폐기는 다른 작업이다. 2026-09-11 운영자는 향후 시험을 위해 lab 유지를 선택했다. 미로그인·sync 비활성 경계를 유지하고, 삭제는 향후 별도 결정 후 처리한다.
