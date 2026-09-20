# Anki 호스트와 MCP 운영 계약

이 문서는 Anki 호스트와 MCP 소스의 운영 계약이다. **구현·격리 검증과 운영 배포 여부는 별도 확인한다.**
도입 이력은 [이슈 #1306](https://github.com/greenheadHQ/nixos-config/issues/1306), 실기기·장애 검증은 [PR #1317](https://github.com/greenheadHQ/nixos-config/pull/1317), iPhone 직접 추가 검증은 [PR #1320](https://github.com/greenheadHQ/nixos-config/pull/1320)에 남긴다.
플러그인의 공통 카드 작성 지침은 [authoring.py](../anki-mcp/src/anki_mcp/authoring.py)가 정본이다.
특정 책·배치·개인 카드 자료와 학습량은 사용자 학습 프로젝트에서 관리한다.

## 카드 작성 지침 전달

공통 지침은 MCP `initialize.instructions`와 `anki_add_notes`·`anki_update_note_fields`의 도구 설명에 함께 전달한다.
초기화 지침을 모델에 노출하지 않는 클라이언트도 내용 쓰기 도구 설명에서 같은 원칙을 읽을 수 있다.
대화에서 이해한 내용의 선별, 필요한 경우의 짧은 이해 확인, 원문 대조, 기존 카드 검색·관계 링크·출처 보존을 안내한다.
단순 조회·그대로 옮기기·오타 수정에는 학습 절차를 강요하지 않는다. 새 도구·필수 인자·노트 유형 변경은 없다.

이는 클라이언트 LLM의 작성 지침이며 서버가 이해도·사실성을 판정하거나 링크를 자동 검증한다는 뜻은 아니다.
원문 확보는 클라이언트의 자료 접근 범위에 달려 있다. 서버는 웹 검색·개인 책 PDF 조회 기능을 제공하지 않는다.
관련 노트는 필드에 플랫폼 URL을 저장하지 않고 `[표시 제목|nid<13자리 note ID>]` 형식으로 저장한다.
Desktop Anki Note Linker와 AnkiMobile 카드 템플릿이 같은 값을 각 클라이언트의 이동 방식으로 렌더링한다.
두 adapter의 설치·실제 탭·복습 복귀 동작은 각각 확인한다.

배포 후 인증된 `initialize`·`tools/list` 응답에서 지침을 확인한다. 서버 응답만으로 ChatGPT 적용 완료라고 판단하지 않는다.
ChatGPT 개발자 모드 연결은 연결 설정에서 **새로 고침(Refresh)**을 실행하고 변경된 도구 설명을 확인한다.
게시된 플러그인의 도구 정의는 정기 스캔과 자동 검사를 거쳐 갱신되며, 통과 전에는 이전 정의가 유지된다.
제출 정보·imported skill 변경은 새 버전 제출·게시가 필요하다 ([개발 연결 새로 고침](https://developers.openai.com/plugins/deploy/connect-chatgpt#refresh-metadata),
[게시 도구의 지속 검토](https://developers.openai.com/plugins/deploy/app-review#continuous-review-and-tool-updates)).
갱신 후 새 대화에서 변경된 지침을 검증하고, iPhone의 실제 작성·링크 동작은 실기기에서 확인한다.
동작하는 연결을 먼저 삭제·재등록하지 않는다. 지침 전달 확인은 LLM 준수나 실기기 동작 검증을 대신하지 않는다.

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

MCP 변경 알림은 한국어 작업명과 처리 결과, AnkiWeb 동기화 상태를 먼저 보여 준다. 대상 수를 실제
변경 수로 단정하지 않는다. 노트 추가에서 확인된 추가 수는 `result.added`로 따로 표시한다.
덱 삭제는 사용자 선택에 따라 **덱 이름과 실제로 함께 삭제된 카드 수**를 표시한다.
helper가 삭제 전후의 덱·카드 ID를 대조해 `result.deleted_decks`, `retained_decks`, `deleted_cards`,
`retained_cards`를 기록한다. 하위 덱·필터 덱의 원래 소속을 포함하고, 유지되는 기본 덱이나 원래 덱으로
돌아간 카드를 삭제했다고 말하지 않는다. 과거 영수증에 실제 삭제 수가 없으면 미확인으로 안내한다.
알림 마지막의 **문제 문의용 작업 번호**는 전체 `operation_id`이며, 비슷한 작업이 여러 건이거나 시간이
지난 뒤에도 `anki_operation_status`로 정확한 결과를 찾는 데 사용한다. 카드 ID와 다르다.
덱 삭제 이름 외의 개인 본문·이름·오류 상세는 알림에 넣지 않는다. 이름의 제어 문자는 눈에 보이게
이스케이프하며, 긴 이름·다수 이름은 Pushover 본문 1,024자 한도 안에서 일부를 보여 주고 생략을 표시한다.
전체 이름은 작업 번호로 조회할 수 있고 작업 번호 자체는 생략하지 않는다.
AnkiWeb 동기화 완료는 다른 기기의 수신 완료를
보장하지 않는다. 구조 변경·일반 동기화·백업의 별도 운영 알림은 기존 경로를 유지한다.

일반 동기화는 백그라운드 미디어 전송의 완료·오류도 확인한 뒤 성공으로 기록한다. 미디어 저장 작업은
`sync.media_state=synced`까지 확인해야 전달 완료다. 미디어 설정이 꺼져 있거나 결과를 확인하지 못하면
`sync.state=pending`을 유지한다. 같은 요청으로 다시 호출하면 파일을 재저장하지 않고 동기화만 재개한다.
컬렉션과 전후 미디어 대기는 기존 변경 작업 예산 30분을 공유한다. 별도의 미디어 대기 시간을 더하지 않는다.
시간 초과 시 성공 기준점을 갱신하지 않으며, 아직 실행 중인 callback의 lock은 완료될 때까지 유지한다.
MCP의 결과 대기는 별도 3분이므로 호출이 먼저 끝날 수 있다. 이 경우 같은 요청 ID의 전달 상태를 다시 확인한다.

## 조회 결과의 동기화 경계

노트·카드 검색/상세·복습 기록, 덱·노트 타입·태그·미디어·덱 옵션 조회는 `freshness`를 함께 반환한다.
`last_successful_sync_at`은 **조회 시작 전에 관측한 호스트↔AnkiWeb의 마지막 성공 시각**이다.
`last_attempt_at`과 `last_attempt_result`는 가장 최근 회차의 마지막 기록이며, 그 회차가 실패했어도 이전 성공 시각은 유지된다.
`running` 기록만으로 현재도 실행 중이라고 판단하지 않는다. 실제 실행 여부는 호스트의 서비스 상태와 로그로 구분한다.
상태 사본이 없거나 손상됐고 시각을 확인할 수 없으면 `null`이다. 조회 시각이나 마지막 시도 시각을 성공 시각으로 대신하지 않는다.

이 값은 휴대폰에서 아직 AnkiWeb으로 보내지 않은 변경을 확인하지 못하므로 `mobile_upload_confirmed`는 항상 `false`다.
휴대폰에서 방금 바꾼 내용이 조회되지 않으면 **AnkiMobile 동기화 → `anki_sync_now` 결과 확인 → 다시 조회** 순서로 확인한다.
조회 자체는 동기화를 실행하지 않으며, 기존 상태 사본을 한 번 읽는 것 외에 HTTP·systemd 호출을 추가하지 않는다.
노트 본문 절단·페이지네이션과 `anki_status`/`anki_sync_now`의 기존 응답·동작은 유지한다.

## 여러 노트의 필드 일괄 수정

`anki_update_notes_fields`는 `{note_id, fields}` 목록을 하나의 작업으로 처리한다. 기존 필드 전체를 먼저 읽고,
바꿀 필드만 전달하며 중복 note ID는 거절한다. 전체 대상·필드·예상 생성 카드 수를 실행 전에 검증한다.
사전/사후 동기화 한 쌍, 검증된 미디어 제외 복구점 하나, 결과 알림 하나를 사용한다.
단일 노트의 `anki_update_note_fields`도 매번 같은 복구점 보호를 적용하지만, 20건 이하 변경에 새 확인 단계를 추가하지 않는다.
읽은 값을 바탕으로 계산한 migration은 바꿀 각 필드의 정확한 이전 값을 `expected_fields`로 함께 보내며,
사전 동기화 뒤 하나라도 다르면 작업 원장을 만들기 전에 전체 요청을 거절한다.

입력별 결과는 `applied`, `unknown`, `not-attempted`로 구분한다. 저장 결과가 불명확하면 이후 항목을 중단하고
전체를 `partial`로 반환한다. 자동으로 되돌리지 않으며 새 request ID로 전체를 반복하지 않는다.
알림에는 요청 노트 수와 실제 확인된 수정 수를 따로 표시한다. 이전 필드의 회수는 아래 복구 절차를 따른다.

## 지원표

소스 핀: Anki **26.08**, AnkiConnect **25.11.9.0**, helper **2.1.0**, MCP SDK **1.29.0**.
Anki 본체를 별도 overlay로 다시 만들지 않고, AnkiConnect 애드온에만 인증·내부 호출 연결 패치를 적용한다.
핀 변경 시 아래 실제 API 테스트를 다시 실행한다. nixpkgs 쪽 세 값의 재검증(helper는 `addons.nix`의 `version`):

```bash
nix eval --raw --impure --expr 'let p = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.x86_64-linux;
  in "anki=${p.anki.version} anki-connect=${p.ankiAddons.anki-connect.version} mcp=${p.python3Packages.mcp.version}"'
```

| MCP 도구 | 실제 API / 주의점 |
|---|---|
| `anki_add_notes`, `anki_update_note_fields`, `anki_update_notes_fields` | `canAddNotesWithErrorDetail`, `addNotes`, `updateNoteFields`; 추가는 `mcp::added`, 입력별 결과. 필드 변경은 새 카드 생성 가능. |
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

## 노트 연결

개념 관계의 저장 형식은 Anki Note Linker의 `[표시 제목|nid1234567890123]`이다. 제목에 `[`가 있으면
`\[`로 이스케이프하고, 다른 링크의 끝으로 해석될 수 있는 `|nid<13자리>]` 문자열은 제목에 넣지 않는다.
note ID는 조회 결과로 확인하고 삭제·재생성·가져오기 뒤 다시 확인한다.
card ID는 사용자가 특정 출제 카드를 LLM에 지목하는 별도 포인터이며 Note Linker 형식에 넣지 않는다.
필드에 raw `anki://x-callback-url`이나 이를 감싼 `<a>`를 저장하지 않는다.

Desktop은 활성 [Anki Note Linker](https://github.com/gugutu/Anki-Note-Linker)가 marker를 내부
Previewer 링크로 바꾼다. macOS URL scheme에 넘기지 않으므로 Finder의 “열도록 설정한 응용 프로그램이 없음”
경로를 사용하지 않는다. MiniPC는 필드·템플릿을 저장하고 동기화할 뿐이므로 GUI add-on을 설치하지 않는다.

AnkiMobile은 add-on을 실행하지 못하므로 링크가 있는 필드의 기존 블록 컨테이너에 `linkRender` class를 추가하고,
카드 뒷면 끝에 `sync-addon/note-link-renderer.html`을 둔다. renderer는 Desktop add-on의
`window.AnkiNoteLinkerIsActive`를 확인해 중복 실행을 피하고, iPhone/iPad에서만 DOM text node를
AnkiMobile의 `nid:` 탐색 링크로 바꾼다. 다른 HTML이나 기존 anchor의 `innerHTML`을 다시 쓰지 않는다.
iPhone의 도착점은 즉시 복습이나 팝업이 아니라 탐색 검색이다.

iPhone에서 링크 검색을 닫으면 실제 복습 화면은 같은 카드의 문제 화면으로 돌아오며 정답을 다시 표시할 수 있다.
다만 `탐색 → 노트 편집 → 미리보기`에서 링크를 열고 돌아오면 미리보기가 비고, 뒤집기에서 JavaScript
예외가 발생하는 경로가 있다. 이때 미리보기를 닫아 편집 화면으로 돌아간 뒤 다시 열면 회복된다.
링크 변환 코드 없는 기본 anchor에서도 재현되며 `target="_blank"`만으로는 해결되지 않는다.
카드 ID widget이 공통으로 있는 환경의 결과이므로 AnkiMobile 자체만의 결함이라고 단정하지 않는다.

순수 계획 생성기 `sync-addon/note_links.py`의 `build_plan(model, targets)`에는 최신 native model 또는
`anki_model_info` 결과와
`template_name`·`front|back`·`field_name` 대상을 명시한다. 자동으로 모든 필드나 노트 타입을 바꾸지 않는다.
필드 토큰이 일반 HTML 본문에 정확히 한 번 있을 때만 감싸고, 중복·부분 설치·불완전 HTML·stale target은
거절한다. 반환한 변경·원복 입력에는 model ID와 양면의 예상 이전 값이 들어간다. helper는 사전 동기화 뒤
현재 값이 이 예상값과 정확히 같을 때만 준비하므로 계획 뒤 바뀐 템플릿을 덮지 않는다. 카드 ID 조각을 포함한
현재 템플릿을 새로 읽어 계획하며 기존 앞면을 재구성하지 않는다. `anki_prepare_model_change`와 아래 root 승인
경로로 적용한다.

실엔진 테스트는 템플릿 적용·원복 전후 note/card/revlog와 카드 ID UI 보존을 검사하지만 JavaScript를
실행하지 않는다. Mac 복습 화면에서는 OS 오류 팝업 없이 내부 Previewer가 정확한 노트를 여는지,
iPhone에서는 탐색 결과가 정확히 한 노트인지와 복습 화면 복귀·일정 무변경을 각각 실측한다.

운영 도입과 기존 raw 링크 이전은 다음 순서를 고정한다.

1. helper 2.1.0과 MCP metadata를 배포·재조회한다.
2. 아래 구조 변경 절차대로 Mac·AnkiMobile을 각각 동기화하고 작업 중 복습·편집을 멈춘다. 호스트도 normal
   sync한 뒤 최신 model을 읽어 CAS가 포함된 템플릿 변경을 준비·root 승인·Upload한다.
3. 운영 계정에 disposable 두 노트만 만들고 서로 연결한다. Mac 내부 Previewer와 iPhone 탐색·복귀가 모두
   정확하고 일정·revlog가 그대로인지 확인한 다음 시험 노트를 삭제하고 개수 복귀를 확인한다.
4. 다시 host sync하고 전체 노트의 모든 필드를 읽어 실제 anchor인 strict legacy shape만 변환한다. 각 수정에
   바꿀 필드의 정확한 이전 값을 `expected_fields`로 함께 넣고 제목·대상 nid·순서, 대상 존재와 raw URL 잔여를
   검사한다.
5. 전체를 하나의 `anki_update_notes_fields` 요청으로 preview한다. 20개 초과 확인을 작은 작업으로 쪼개
   우회하지 않고 같은 request ID·token으로 승인한다.
6. 전체 readback에서 marker 수와 이전 manifest가 일치하고, 다른 필드·note/card ID·태그·flag·일정·revlog가
   보존됐는지 확인한다. Mac·iPhone을 동기화해 이전된 실제 링크 하나를 다시 실측한다.

필드 복구점과 템플릿 원본은 서로 다른 복구 경로다. 실패 시 운영 프로필에 `.colpkg`를 직접 import하지 않는다.

## 카드 ID 복사

복습 화면의 `카드 ID 복사` 버튼은 현재 카드의 `{{CardID}}`를 문자열로 받아 `cid:<ID>`를 복사한다.
같은 카드의 문제·정답 화면에서는 같은 값이고, 같은 노트에서 만든 형제 카드는 각각 다른 값이다.
`anki_find_cards(query="cid:<ID>")` 응답의 `noteId`로 원본 노트와 검토 메모를 찾을 수 있다.
번호를 별도 필드에 저장하거나 노트 ID로 오표기하지 않는다.

조각의 정본은 `sync-addon/card-id-button.html`, 순수 계획 생성기는 `sync-addon/card_id.py`의
`build_plan(model)`이다. 현재 Anki native model의 `flds`, `tmpls`, `req`를 받아 원본과 변경안 쌍을 반환하며
컬렉션을 직접 읽거나 바꾸지 않는다. 원래 ALL/ANY 카드 생성 조건 안에만 버튼을 넣고, `FrontSide`가 있는
뒷면은 앞면의 버튼을 상속한다. 기존 CSS·필드·템플릿 본문은 유지하며, 불명확한 HTML이나 중복 설치는 거절한다.
실제 적용은 각 변경안을 `anki_prepare_model_change(action="model_template_update", ...)`로 준비한 뒤
아래 root 승인·복구점 경로를 따른다. 변경안은 원본 template을, `original` 원복 입력은 적용된 template을
각각 예상 이전 값으로 묶어 계획 뒤 최신 편집을 덮지 않는다.

적용된 타입의 기존 카드와 이후 생성 카드는 같은 버튼을 사용한다. 새로 만들거나 가져온 **다른 노트 타입**에는
자동 설치하지 않는다. 이 경우 원본을 확인하고 같은 준비·기기 검증 절차를 거친다.
카드 ID를 렌더하지 못하는 클라이언트에서는 복사를 비활성화한다. 자동 복사가 거절되면 선택 가능한 번호를
보여 주며 성공으로 표시하지 않는다. 복사 자체는 서버 조회를 하지 않지만, LLM이 해당 카드를 찾으려면
클라이언트와 호스트의 AnkiWeb 동기화가 끝나 있어야 한다.

검증은 `tests/anki-runtime/test_card_id_templates.py`의 실제 카드 생성·렌더링·보존·원복 검사와,
Mac/iPhone에서 문제·정답·형제 카드의 버튼을 누른 뒤 실제로 붙여넣은 값의 대조를 구분한다.
버튼 클릭으로 정답이 열리거나 평가되지 않는지도 확인한다. API 성공 반환이나 성공 문구만으로
실기기의 클립보드 호환성을 확정하지 않는다.

## Mac GUI 자동화 안전 경계

Computer History 관찰 설정에서는 Anki bundle ID `net.ankiweb.anki`를 제외한다. 이 규칙은 백그라운드
Computer History에만 적용되며, 명시적인 Computer Use를 Anki 전체에서 금지하지 않는다. 일반 덱 선택·복습·
동기화 화면과 iPhone Mirroring은 계속 사용할 수 있다.

Anki 26.9.2/Qt 6.11.2에서 선택된 행이 있는 `탐색` 창의 접근성 트리를 읽을 때 `libqcocoa`의
`NSAccessibility` 경로로 충돌한 기록이 있고, 사용자는 편집 창에서도 반복 충돌을 보고했다.
개인 데이터·동기화 계정 없이 AnkiConnect만 설치한 격리 프로필에서도 `탐색` 창을 API로 연 뒤에는 생존했지만,
Computer Use의 스크린샷 요청 직후 같은 접근성 계층 조회에서 충돌했다. Computer History 제외만으로 직접
Computer Use 호출의 충돌을 막을 수 없으며, 스크린샷만 요청하는 방식도 안전한 우회가 아니다.
같은 격리 환경의 기본 `Edit Current` 창은 접근성 조회·스크린샷 1회씩 성공했으나, 운영 확장 프로그램과
모든 편집 상태의 안전을 보장하지 않는다. 재검증은 이처럼 격리 프로필에서 창·확장 구성·조회 방식을 구분한다.
운영 구성에 대응하는 격리 프로필의 A/B 재현 시험을 통과하기 전까지 독립·내장 편집 창 또는 선택 행이 있는 `탐색` 창을 Computer Use로
열지 않으며, 그 안에서 조회·클릭·키 입력·스크롤 등 어떤 Computer Use 조작도 하지 않는다. MCP/API나 사용자
수동 조작을 사용하고, 위험 창을 닫으면 일반 화면에서 Computer Use를 재개한다. 근거는 [Anki selected-row Browse 충돌](https://forums.ankiweb.net/t/macos-accessibility-scan-can-crash-browse-when-a-row-is-selected/70882)과
[Codex Qt 앱 접근성 충돌 #41374](https://github.com/openai/codex/issues/41374)이다.

## 검토 표시와 메모

이 개인용 환경의 검토 대기열은 사용자 결정에 따라 **별표**를 사용한다.
별표는 노트의 `marked` 태그이며, `anki_find_notes(query="tag:marked")`의 모든 페이지를 모은 뒤
`anki_note_info`로 검토 메모와 본문 전체를 읽는다. 같은 노트에서 나온 여러 카드는 함께 검토한다.
요청한 검토 작업과 필요한 결과 확인을 마치면 결과와 완료 대상을 알리고, 해당 노트들의 정리 방식을 **한 번에** 묻는다.
선택지는 **별표·메모 모두 지우기 / 별표만 해제하고 메모 보관 / 둘 다 유지**다.
목록을 보여 주거나 내용을 읽기만 한 것은 작업 완료로 간주하지 않는다. 답변 전에는 둘 다 유지하며,
사용자가 이미 같은 대상과 정리 방식을 명시적으로 승인했다면 다시 묻지 않는다.
미완료 작업이나 메모 속 미해결 질문이 남은 노트는 정리 대상에서 제외한다. 형제 카드에 관한 질문도 포함한다.
정리 직전 전체 메모를 다시 읽고, 선택지를 제시한 뒤 내용이 바뀌었으면 보존하고 다시 확인한다.
승인된 노트의 기존 `검토 메모` 값만 빈 문자열로 비우거나 `marked`만 해제한다. 다른 필드·태그·깃발·일정은 유지한다.
둘 다 정리할 때는 메모를 비우고 결과를 확인한 뒤 별표를 해제한다. 일부 실패·결과 불명이면 상태를 재조회하고
남은 내용을 보고하며, 새 요청 번호로 전체 정리를 반복하지 않는다.
이는 기존 조회·필드 수정·태그 도구를 사용하는 LLM 지침이다. 서버가 대화의 완료·동의를 자동 판정하는 기능은 아니다.
재조회는 확인 시점의 상태만 확인한다. 조회 후 변경 도구의 사전 동기화·준비 전에 새 내용이 들어오는 경우까지
보호하는 원자적 조건부 쓰기(CAS)는 현재 제공하지 않는다.
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

구조 변경은 AnkiWeb에서 전체 Upload를 요구할 수 있으므로, 먼저 연결된 Mac·AnkiMobile을 각각 직접 동기화해
로컬 변경을 AnkiWeb에 올리고 성공 화면을 확인한다. 그 뒤 구조 변경·Upload·각 클라이언트의 후속 동기화가
끝날 때까지 모든 클라이언트에서 복습·편집을 중지한다. 호스트의 `mobile_upload_confirmed=false`는 이 절차를
대신할 수 없다. 어떤 클라이언트에 미전송 변경이 남았는지 불명확하면 구조 변경을 시작하지 않는다.

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
