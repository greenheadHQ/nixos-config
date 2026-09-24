# Anki 호스트와 MCP 운영 계약

이 문서는 Anki 호스트와 MCP 소스의 운영 계약이다. **구현·격리 검증과 운영 배포 여부는 별도 확인한다.**
도입 이력은 [이슈 #1306](https://github.com/greenheadHQ/nixos-config/issues/1306), 실기기·장애 검증은 [PR #1317](https://github.com/greenheadHQ/nixos-config/pull/1317), iPhone 직접 추가 검증은 [PR #1320](https://github.com/greenheadHQ/nixos-config/pull/1320)에 남긴다.
플러그인의 공통 카드 작성 지침은 [authoring.py](../anki-mcp/src/anki_mcp/authoring.py)가 정본이다.
특정 책·배치·개인 카드 자료와 학습량은 사용자 학습 프로젝트에서 관리한다.

## 카드 작성 지침 전달

공통 지침은 MCP `initialize.instructions`와 `anki_add_notes`·`anki_update_note_fields`의 도구 설명에 함께 전달한다.
초기화 지침을 모델에 노출하지 않거나 일부만 노출하는 클라이언트도 내용 쓰기 도구 설명에서 같은 원칙을 읽을 수 있다.
ChatGPT는 초기화 지침의 앞 169자만 앱 설명 뒤에 붙여 모델에 전달했고, 도구 설명은 자르지 않았다
(2026-09-24 관측, [#1359](https://github.com/greenheadHQ/nixos-config/issues/1359)).
모든 클라이언트의 모델이 읽어야 하는 안내는 초기화 지침 뒤쪽이 아니라 관련 도구 설명에 둔다.
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

### 메타데이터 대조와 배포 완료 조건

도구·설명·스키마·annotation·초기화 지침을 바꾸면 아래 세 단계를 각각 기록한다.

1. **서버**: 배포한 소스와 실행 서비스의 SDK·설정으로 내보낸 명세를 `full` 범위로 대조한다.
   인증된 `initialize`·`tools/list` 응답도 확인한다. 서비스 재시작 성공만으로 완료하지 않는다.
2. **ChatGPT 등록**: 개발 연결을 Refresh한 뒤 등록 화면의 전체 도구 이름·설명·입력 스키마·읽기/쓰기
   분류를 저장하고 `registration` 범위로 대조한다. 누락·차이·필수 항목 미관측이면 갱신 확인은 미완료다.
3. **Chat 실행**: 새 Chat에서 변경된 도구를 실제로 검색해 노출을 확인한다. 모델·시각·검색 인자와
   반환 목록을 남긴다. 쓰기 실행·iPhone 동작은 승인된 검증에서 별도로 확인한다.

등록 목록과 한 응답에 노출된 목록은 서로 다른 관측이다. Chat에서 도구가 안 보인다는 이유만으로
서버 기능 부재나 등록 drift를 확정하지 않는다. 등록 대조가 통과해도 Chat 실행 검증이 안 됐으면 그 상태를 남긴다.

저장소 루트의 `nix develop` 환경에서 다음 명령으로 비교용 명세를 만든다. `fieldCharsDefault`는
두 조회 도구의 입력 스키마 기본값에 영향을 주므로 설정에서 읽는다. 명령은 Anki·OAuth·동기화에 접근하지 않는다.

```sh
anki_field_chars=$(nix eval --impure --raw --expr 'toString (import ./libraries/constants.nix).ankiMcp.fieldCharsDefault')
PYTHONPATH=modules/nixos/programs/anki-mcp/src nix shell .#ankiMcpTestEnv -c \
  python -m anki_mcp.metadata export --field-chars "$anki_field_chars" > /tmp/anki-source.json
PYTHONPATH=modules/nixos/programs/anki-mcp/src nix shell .#ankiMcpTestEnv -c \
  python -m anki_mcp.metadata compare /tmp/anki-source.json /tmp/anki-registration.json --scope registration
```

실행 서비스 명세는 서비스의 Python·`PYTHONPATH`·`ANKI_MCP_FIELD_CHARS`로 같은 exporter를 실행하고
`--source server`를 지정한다. 이 표시는 수집 경로의 기록이며 HTTP 통신 성공의 증거가 아니다.
인증된 HTTP 응답을 저장할 때는 모든 `tools/list` 페이지를 수집하고 `initialize.instructions`를 포함한다.
각 도구는 `mcp.types.Tool.model_validate(tool).model_dump(mode="json", by_alias=True)`로 선택 필드를
복원한다. `compare`는 이 정규화를 대신하지 않는다. 등록 UI에서 숨겨진 필드는 소스 값으로 채우지 않는다.

관측 JSON은 `source`(`source`, `server`, `chatgpt-registration`, `chat-turn`), 시간대가 있는 ISO
`observed_at`, 전체 도구 목록 수집 여부인 `complete`, `tools` 배열을 가진다. `instructions`와 각 도구의
`description`, `inputSchema`, `outputSchema`, `annotations` 등은 **실제로 관측한 필드만** 포함한다.
도구 이름은 `name`, 등록 화면의 읽기/쓰기 분류는 `annotations.readOnlyHint`로 저장한다.
예를 들어 한 Chat에서 이름 하나만 확인한 불완전 관측은 다음처럼 기록한다.

```json
{
  "source": "chat-turn",
  "observed_at": "2026-09-22T12:00:00+09:00",
  "complete": false,
  "tools": [{"name": "anki_status"}]
}
```

명령은 도구 누락·추가와 필드별 변경 경로를 출력한다. 종료 코드는 `0=match`, `1=drift`,
`2=unknown 또는 invalid`다. 기본 `full`은 SDK 전체 명세, `registration`은 이름·설명·입력 스키마·
`readOnlyHint`를 필수로 비교하며 추가로 관측한 필드의 차이도 검출한다. 배열과 설명은 임의로 정규화하지 않는다.
등록 대조가 `match`여도 숨겨진 `outputSchema`·다른 annotation·초기화 지침이 있으면 `full_status=unknown`이다.
불완전 목록과 `chat-turn`은 차이 내역을 보여 주되 등록 drift나 정상으로 확정하지 않는다.
이 비교의 회귀 테스트와 인증된 ASGI 응답 대조는 기존 Anki MCP 테스트 및 required `check` CI에 포함된다.

## 변경 요청과 결과 확인

1. `anki_status`, 검색·상세 조회로 현재 대상과 ID를 확인한다.
2. 논리적 변경마다 8–128자의 `request_id`를 정한다(영문·숫자·`_`·`-`, 첫 글자는 영문·숫자).
3. 변경 도구를 호출한다. 일반 동기화의 **새 회차 성공** 뒤 준비하며, 작은 변경은 바로 실행된다.
   ChatGPT 클라이언트는 작은 변경도 미리보기로 시작한다(아래 'ChatGPT 쓰기 확인').
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
미완료 본문도 만료 정리 시 제거한다. 원장은 파일 0600·디렉터리 0700으로 생성하며, 원장 파일은 삭제하지 않고 무기한 보존한다.
같은 `request_id`는 같은 작업 ID로 이어지므로, 원장을 지우면 재시도가 새 변경으로 다시 적용될 수 있다.
원장은 컬렉션 백업·복구점(`.colpkg`)에 포함되지 않으며, 복구점 보존은 아래 '복구점과 장애 조사' 절을 따른다.
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

### ChatGPT Pro 계열에서 쓰기

ChatGPT Pro 계열 모델은 한 메시지에 응답 후보 여러 개를 병렬로 만들고 그중 하나만 보여 준다.
2026-09-24 관측에서는 한 턴에 전체 도구(35개)를 받는 후보가 하나뿐이었고, 나머지 후보는 읽기 도구(16개)만 받았다.
보이지 않은 후보가 보낸 쓰기도 서버에 도달했고, 보이는 응답은 쓰기 도구가 없어 실행하지 않았다고 답했다.
미리보기 대상이 아닌 20건 이하 변경(추가·필드 수정·태그·미디어 저장 등)은 그런 쓰기도 바로 반영됐다.
지금은 아래 'ChatGPT 쓰기 확인'이 ChatGPT의 모든 변경을 미리보기에서 멈춘다.
비-Pro 모델(Thinking 등)은 후보가 하나라 이 차이가 없었다. 측정 방법과 턴별 기록은 [#1359](https://github.com/greenheadHQ/nixos-config/issues/1359)에 있다.

- 카드 추가·수정·태그·미디어 저장 같은 쓰기는 비-Pro 모델에서 요청한다. Pro는 설명·조회·초안 작성에 쓴다.
- 쓰기 요청마다 `request_id`를 정해 주고, 다시 요청할 때도 같은 ID를 쓴다. 서버는 같은 ID·같은 내용을
  다시 실행하지 않고 기존 결과를 돌려준다.
- 응답이 쓰기 도구가 없다고 하면 다시 요청하기 전에 `anki_recent_operations`와 대상 노트로 실행 여부를 확인한다.

같은 안내를 두 곳에 둔다.

- `anki_recent_operations` 도구 설명의 한 문장. 읽기 도구만 받는 후보도 이 설명은 받는다.
- ChatGPT 앱 설명(설정 > 플러그인 > Anki > 앱 관리 > 앱 설명). 모델 컨텍스트에서 서버 지침보다 앞에 붙고,
  ChatGPT에서만 쓰여 다른 클라이언트의 지침에는 더해지지 않는다. 저장소 밖 설정이라 현재 값을 아래에 기록한다.
  배포 뒤 "액션 새로 고침"을 실행해도 이 값은 바뀌지 않았다.

  > 셀프호스팅 Anki 컬렉션 조회 및 관리. 쓰기 도구가 이번 응답에서 보이지 않아도 쓰기가 실행되지 않았다고 단정하지 말 것: 같은 메시지의 다른 응답이 이미 실행했을 수 있다. 재시도 전에 anki_recent_operations 확인을 안내하고, 재시도는 같은 request_id로만 한다.

같은 요청을 5.5·5.6·6 Pro에 보낸 2026-09-24 측정에서 쓰기 도구가 없는 후보가 "쓰기가 없었다"고 단정한 비율은
변경 전 7/10, 도구 설명만 추가했을 때 3/10(부분 단정 2 별도), 앱 설명을 더한 뒤 0/17이었다.
재시도 전 확인과 같은 `request_id`를 안내한 응답은 앱 설명을 더한 뒤에만 나왔다.
표본이 작고 서버가 저장 전에 거절하는 빈 파일 저장 요청으로만 측정했으므로, 실제 카드 추가 요청의 행동으로 일반화하지 않는다.
후보 수·도구 분배·지침 전달 범위는 ChatGPT 변경으로 달라질 수 있다. 다시 확인할 때는
[#1359의 재현 절차](https://github.com/greenheadHQ/nixos-config/issues/1359#issuecomment-5804845469)
(서버 루프백 캡처와 읽기 도구 보고 채널)를 따른다.

### ChatGPT 쓰기 확인

OAuth 등록의 redirect URI 호스트가 `constants.ankiMcp.writeConfirmGate.redirectHosts`(현재 `chatgpt.com`)인
클라이언트는 모든 컬렉션 변경이 미리보기로 시작한다. 20건 이하 변경과 관리 노트 유형 제한 복구도 포함한다.
대상은 요청 헤더가 아니라 bearer 토큰이 가리키는 등록 클라이언트로 판정한다. Claude 등 다른 클라이언트는 위 기존 규칙을 따르고,
구조 변경의 root 승인과 `anki_sync_now`는 바뀌지 않는다.

1. 첫 호출은 아무것도 적용하지 않고 미리보기와 `confirmation_required=true`, `confirmation_policy=separate-user-message`를 돌려준다.
2. 모델은 미리보기를 보여 주고 사용자의 답을 기다린다.
3. 사용자의 **다음 메시지**에서 같은 인자·`request_id`·`preview_token`에 `confirm=true`를 넣어 호출하면 적용한다.

서버는 W3C `traceparent` 헤더의 trace-id로 사용자 메시지를 구분한다. ChatGPT는 메시지마다 새 trace-id를 보냈고,
같은 메시지의 병렬 후보는 같은 값을 보냈다(2026-09-24 관측, 공개 계약 아님). 미리보기를 만든 메시지의 trace-id로 온 확인은
거절하므로, 보이지 않는 후보가 한 메시지 안에서 미리보기와 확인을 모두 보내도 적용되지 않는다.
거절 응답은 `confirmation_blocked`와 다음 행동 안내를 담는다.

| `confirmation_blocked` | 뜻 |
|---|---|
| `confirmation-requires-a-new-user-message` | 미리보기와 같은 메시지에서 온 확인이다. 사용자 답 뒤에 다시 확인한다. |
| `confirmation-preview-not-recorded` | 서버에 미리보기 기록이 없다(재시작 등). 이번 메시지를 기록했으므로 다음 메시지에서 다시 확인한다. |
| `confirmation-trace-unavailable` | trace-id가 없거나 형식이 다르다. 확인하지 못한 요청은 적용하지 않는다. |

미리보기 기록은 프로세스 메모리에만 둔다. 확인 토큰의 10분 만료(`operationTtlSecs`)는 그대로다.
응답이 긴 Pro 모델에서 미리보기와 확인 사이에 10분이 지나면 새 `request_id`로 미리보기부터 다시 한다.

이 확인은 서버가 관찰한 대화 순서이며 사람 인증이 아니다. 남는 한계는 다음과 같다.

- 확인 메시지에서 쓰기 도구를 받은 후보도 보이지 않을 수 있다. 사용자가 확인한 변경은 적용되지만 보이는 응답은
  실행하지 않았다고 말할 수 있으므로, 앞 절의 재시도 전 확인 안내는 계속 필요하다.
- 서버는 사용자가 미리보기를 실제로 봤는지 모른다. 준비된 미리보기와 토큰은 `anki_recent_operations`에도 보이므로,
  보이지 않은 후보가 만든 미리보기를 다음 메시지의 후보가 확인할 수 있다.
- 후보마다 다른 trace-id를 보내게 되면 같은 메시지의 확인을 막지 못한다. trace-id를 보내지 않게 되면 ChatGPT의 변경이
  모두 거절된다. `confirmation-trace-unavailable`이 반복되면 #1359의 재현 절차로 요청 헤더를 다시 확인한다.

`constants.ankiMcp.writeConfirmGate.enable = false`로 배포하면 끈다. ChatGPT 변경도 20건 이하는 바로 실행되는 기존 규칙으로 돌아가고,
보이지 않는 후보의 쓰기가 바로 반영되는 위험도 돌아온다.
20건 이하를 바로 실행하는 규칙은 [#1306](https://github.com/greenheadHQ/nixos-config/issues/1306)의 2026-09-06 결정이다.
ChatGPT에서만 바꾼 근거는 앞 절의 측정이다. 다른 클라이언트에서는 이 현상을 관측하지 않았으므로 기존 결정을 유지한다.

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
| `anki_delete_notes` | `deleteNotes`; 해당 노트의 모든 카드를 삭제하고 복습 기록은 보존. 항상 확인·복구점. |
| `anki_delete_decks` | `deleteDecks(cardsToo=True)`; 하위 덱 포함. 다른 덱의 형제 카드는 유지, 고아 노트는 삭제, 복습 기록은 보존. filtered/default 덱 경고는 preview에서 확인. |
| `anki_suspend_cards` | `suspend` + `areSuspended` readback; 정지와 해제 모두 지원. |
| `anki_find_cards`, `anki_set_card_flags` | `flag:N` 검색과 응답 `flag`(0–7, 조회 불가 시 null). 설정은 Anki `set_user_flag_for_cards` + readback; 1–7 설정/변경, 0 해제. 지정 카드만 변경하며 노트·형제 카드·일정·복습 기록을 보존. 20건 초과 확인·복구점 적용. |
| `anki_set_due_date` | `setDueDate`; `2`, `2-5`, `2!` 문법. 범위는 무작위, 수동 복습 기록 추가·정지 해제 가능. |
| `anki_forget_cards` | `forgetCards`; 새 카드 학습 상태로 돌아가며 과거 복습 기록 전체를 지우지 않는다. |
| `anki_store_media`, `anki_media` | base64 신규 저장·이름 목록/조회. decoded 5 MiB, 안전한 NFC 파일명. 같은 내용은 no-op, 다른 내용의 덮어쓰기·삭제·URL/path 입력은 없음. |
| `anki_deck_options`, `anki_update_deck_options` | `getDeckConfig`, `saveDeckConfig`; 현재 프리셋 ID 고정, 공유 덱 목록 표시. 아래 허용 값만 patch. |
| `anki_model_info`, `anki_prepare_model_change` | 필드 add/remove/rename/reposition, 템플릿 add/remove/update. 준비만 수행하고 root 승인 경로에서 적용. |
| `anki_update_model_css` | `updateModelStyling`; 빈 CSS도 지원, 구조 변경과 별도. |
| `anki_sync_now` | 기존 normal systemd 서비스 실행. 전체 동기화 방향 선택 인자 없음. |

삭제 preview의 `affected_review_rows`는 **실행 전 대상 카드에 연결된 복습 로그 수**이며 삭제할 기록 수가 아니다.
이 키는 기존 호출과의 호환을 위해 유지한다. 결과의 `retained_review_rows`는 같은 카드 ID에 남아 있는 로그를
실행 후 다시 센 값이다. 로그가 실행 전과 달라지면 `partial`로 보고하고, 직접 SQL로 이력을 삭제하지 않는다.
노트·카드·덱 삭제는 Anki API의 삭제 표식(tombstone)을 통해 동기화하지만 복습 로그 제거 기능은 제공하지 않는다.

상태의 `today_reviews`와 MCP `reviewed_today`는 Anki 학습일 시작 이후의 **전체 복습 로그 행 수**다. 삭제된 카드의 기록과 수동 일정 변경
기록도 포함하므로, 현재 카드 수나 실제로 답한 횟수와 같다고 해석하지 않는다. `today_reviews_by_deck`는
현재 존재하는 카드와 연결되는 로그만 현재 덱별로 집계하므로 그 합이 전체보다 작을 수 있다.
카드를 삭제해도 `today_reviews`가 줄지 않는 것은 이 계약에 맞는 동작이다.

덱 옵션 허용 키는 adapter의 `OPTION_RANGES`가 정본이다:
`new.perDay`, `new.order`, `new.initialFactor`, `rev.perDay`, `rev.maxIvl`, `rev.ease4`,
`rev.ivlFct`, `rev.hardFactor`, `lapse.mult`, `lapse.minInt`, `lapse.leechFails`, `lapse.leechAction`.
현 버전에서 없는 키·범위 밖 값·프리셋 ID/name 교체는 거부한다. FSRS 설정 전체 편집은 지원하지 않는다.

## 노트 연결

`add_notes`, `update_fields`, `update_fields_bulk`, `delete_notes`, `delete_decks`의 완료 영수증에는
`link_check`가 포함된다. 호스트에서 쓰기 직전·직후 전체 노트의 저장된 Note Linker 참조 후보를 읽고,
이번 작업 중 새로 끊어진 참조만 알린다. 기존에 끊긴 참조는 반복하지 않으며, 같은 노트·필드·대상의
발생 수가 늘어난 경우 증가분을 센다. 삭제한 노트를 가리키는 다른 노트의 참조도 포함된다.

`state=checked`의 `new_missing_occurrences`와 `new_missing_references`는 각각 증가한 발생 수와
서로 다른 `(source_note_id, field_name, target_note_id)` 수다. `references`는 최대 50개 포인터만
포함하고, 잘리면 `truncated=true`다. 필드 원문과 제목은 검사 영수증에 저장하지 않는다.
HTML 인라인 서식은 이어 읽고 코드·수식·속성·Markdown 코드 예제는 제외한다. 카드 템플릿,
조건부 표시, 실제 클라이언트 렌더링을 평가하지 않으므로 결과는 **저장된 참조 후보**에 대한 검사다.
전체 마커 앞에 역슬래시가 있어도 Desktop Note Linker에서는 링크가 될 수 있으므로 후보에 포함한다.

검사 결과와 쓰기·동기화 결과는 별개다. `state=unavailable`은 진단 실패이며 성공한 쓰기를 실패로
바꾸지 않는다. 쓰기가 `partial` 또는 `unknown`이면 검사가 끝났더라도 쓰기 완료를 의미하지 않는다.
LLM은 영수증의 포인터로 현재 노트를 다시 조회하고 사용자에게 결과를 설명한다. 검사를 재실행하려고
쓰기를 반복하거나 새 `request_id`를 만들지 않는다. 같은 요청의 재시도와 상태 조회는 저장된 검사
영수증을 그대로 반환한다. 자동 수선, 별도 Pushover 경고·주기적 감시, 모델 변경이나 다른 기기의
변경 감시는 이 검사에 포함하지 않는다.

개념 관계의 저장 형식은 Anki Note Linker의 `[표시 제목|nid1234567890123]`이다. 제목에 `[`가 있으면
`\[`로 이스케이프하고, 다른 링크의 끝으로 해석될 수 있는 `|nid<13자리>]` 문자열은 제목에 넣지 않는다.
note ID는 조회 결과로 확인하고 삭제·재생성·가져오기 뒤 다시 확인한다.
card ID는 사용자가 특정 출제 카드를 LLM에 지목하는 별도 포인터이며 Note Linker 형식에 넣지 않는다.
필드에 raw `anki://x-callback-url`이나 이를 감싼 `<a>`를 저장하지 않는다.

끊어진 링크는 `files/audit-note-links.py`로 읽기 전용 진단한다. `anki_find_notes(query="", max_field_chars=0)`의
모든 페이지를 모은 `notes`와 서버가 보고한 전체 개수 `page.total`을 JSON에 넣는다. 검색으로 제한하거나
본문이 잘린 결과는 사용하지 않는다. 전체 개수·고유 note ID가 맞지 않으면 검사기가 거절한다.

```bash
python3 modules/nixos/programs/anki-host/files/audit-note-links.py \
  --input /private/path/notes.json --output /private/path/link-report.json
```

보고서는 source note·field·표시 제목·target note ID·원문 위치·대상 존재 여부와 누락 대상별 집계를 담는다.
이는 저장된 marker 전체의 진단이며 코드 예제나 HTML 속성 속 marker도 포함한다. 실제 링크 여부와 원문
맥락은 수선 전에 확인한다. 보고서는 학습 내용을 포함하므로 비공개로 보관한다(출력 파일 0600,
기존 파일·심볼릭 링크 덮어쓰기 금지). 표준 출력에는 개수만 표시한다.

수선 후보는 현재 노트를 조회해 확인하고, 같은 제목이라는 이유만으로 재생성된 동일 노트라고 단정하지 않는다.
한 옛 ID가 여러 개념에 쓰였으면 각 source field의 링크별로 판단한다. 사용자에게 구체적 변경안을 보여 주고
승인된 항목만 기존 일괄 필드 수정과 정확한 `expected_fields`로 적용한다. 원래 제목·순서·HTML과 다른
필드·태그·카드 일정은 보존한다. 자동 삭제·추측 연결·새 노트 생성은 하지 않는다. 적용 전 검증된 복구점을
확인하고 적용 후 전체 진단을 다시 실행하여 남긴 항목과 수정 결과를 구분한다.

Desktop은 활성 [Anki Note Linker](https://github.com/gugutu/Anki-Note-Linker)가 marker를 내부
Previewer 링크로 바꾼다. macOS URL scheme에 넘기지 않으므로 Finder의 “열도록 설정한 응용 프로그램이 없음”
경로를 사용하지 않는다. MiniPC는 필드·템플릿을 저장하고 동기화할 뿐이므로 GUI add-on을 설치하지 않는다.

AnkiMobile은 add-on을 실행하지 못하므로 링크가 있는 필드의 기존 블록 컨테이너에 `linkRender` class를 추가하고,
카드 뒷면 끝에 `sync-addon/note-link-renderer.html`을 둔다. renderer는 Desktop add-on의
`window.AnkiNoteLinkerIsActive`를 확인해 중복 실행을 피하고, iPhone/iPad에서만 DOM text node를
AnkiMobile의 `nid:` 탐색 링크로 바꾼다. 다른 HTML이나 기존 anchor의 `innerHTML`을 다시 쓰지 않는다.
iPhone의 도착점은 즉시 복습이나 팝업이 아니라 탐색 검색이다.

모바일 renderer v3는 제목 안의 `b`·`sup`·`u` 같은 inline 서식이 여러 text node로 나뉘어도
기존 요소를 그대로 링크 안으로 옮긴다. 표시 제목·서식·entity의 표시 결과를 유지하며, 노트 필드는 수정하지 않는다.
대괄호와 `|nid<13자리>]`가 같은 부모 요소 안에 있고 nid suffix가 한 text node일 때만 처리한다.
부분 태그 경계를 걸친 marker, block·줄바꿈·주석을 넘는 marker, 기존 anchor·코드·수식·편집 요소는
변환하지 않는다. 제목의 `\[`는 기존 Note Linker 규칙대로 표시하며, marker 전체 앞에 `\`가 붙으면 그대로 둔다.
재사용 WebView에서도 이전 renderer 함수를 버전별로 교체하고 반복 실행 시 이미 만든 anchor는 건너뛴다.
DOM 회귀 검사는 `nix develop --command bash tests/run-anki-code-highlight-tests.sh`에 포함된다.
관리 대상 Basic 템플릿의 알려진 renderer만 준비 도구로 업그레이드한다. 기존 KaTeX 타입의 별도
Markdown·Cloze 링크 처리는 교체하거나 덧붙이지 않는다. 그 타입의 제목 표본은 입력 호환성 검증에만 사용한다.

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

## 코드 블록 강조

`CS 재활 Basic`의 명시적으로 선택한 필드에만 `code_highlighting.py` 계획을 적용한다.
질문·답·설명·출처의 `<pre><code class="language-javascript">…</code></pre>`를 표시할 때
로컬 highlight.js로 색칠한다. 저장 필드에는 원문과 언어만 남기며 구문별 span은 저장하지 않는다.
문장 안 `<code>`는 기존 단색 서식을 유지한다. 구형 KaTeX/Markdown/Cloze 템플릿은 변경하지 않는다.

지원 이름은 javascript/js/jsx, typescript/ts/tsx, html/xml, css, json, bash/sh/shell,
sql, c, python/py, java, yaml/yml, http다. 미지정·미지원·plaintext는 자동 추측 없이 단색이다.
`&`, `<`, `>`는 HTML text로 이스케이프하고 들여쓰기와 개행을 보존한다.
코드 예제에 실제 HTML 자식 요소나 cloze span이 있으면 강조를 건너뛰며 평탄화하지 않는다.
HTML 소스 자체를 실행하는 기능은 없다.

코드는 앱의 밝은/어두운 모드를 따르고, 긴 줄은 코드 블록 내부에서 가로 스크롤한다.
별도 scoped style을 삽입하므로 기존 모델 CSS 필드는 수정하지 않는다.
화면 폭 600px 이하는 코드 기본 크기 15px·안쪽 여백 12px, 그보다 넓으면
17px·상하 14px/좌우 16px을 사용한다. 질문·답·설명·출처에서 코드 기본 크기는 같다.
본문과 인라인 코드 크기는 바꾸지 않으며, plaintext 도식도 원래 공백·개행을 보존한다.

첫 표시 가능한 코드블록 바깥 우상단에 `− / 배율 / + / ↺` 조작부를 한 번 표시한다.
큰 테두리·배경 없이 표시하고, 버튼은 데스크톱 28px·좁은 화면 32px로 구성한다.
접힌 `details`나 `hidden` 영역은 배치 대상에서 제외한다. 설명을 펼치거나 접으면
위치를 다시 계산하며, 모든 코드가 접혀도 현재 카드의 배율은 유지한다.
현재 카드의 모든 코드블록을 기본 크기의 80–140% 범위에서 10%씩 조절하고,
`↺`는 현재 화면 폭에 맞는 100%로 되돌린다. 배율은 코드 영역에만 적용되며
카드 ID가 같은 앞뒷면에서는 유지하고, 다음 카드 또는 답에서 질문으로 돌아갈 때 초기화한다.
유효한 CardID가 없는 미리보기는 같은 DOM에서의 재실행만 유지하며 화면 교체 시 초기화한다.
브라우저 저장소·노트 필드·저장된 모델 정의에 배율을 기록하지 않는다.
버튼에만 이벤트 전파를 차단하므로 코드 영역의 가로 스크롤은 그대로 사용한다.
색칠 라이브러리를 읽지 못해도 글자 크기는 조절할 수 있다.

블록당 4,096자·한 화면 총 16,384자·32블록을 초과하면 남은 블록은 단색으로 표시한다.
16ms를 넘으면 다음 블록 처리를 시작하지 않지만, 실행 중인 한 블록의 시간을 중단하는 보장은 아니다.
미디어 로드가 실패해도 원문은 즉시 읽을 수 있고 다음 카드에서 다시 시도한다.

기존 설치의 UI를 바꿀 때는 공통 CSS·renderer와 관리 원장의 앞뒷면 사본을 함께
갱신한 뒤 내용 버전을 다시 계산한다. 재사용 WebView에서도 현재 CSS를 갱신한다.
DOM 테스트는 조작·범위·카드 전환·원문 보존을 검증하지만 실제 배치를 측정하지 않는다.
PC의 좁은/넓은 창과 iPhone의 세로/가로 화면에서 글자 크기, 버튼 위치,
여러 코드블록의 동시 변경, 가로 스크롤과 복습 제스처를 따로 확인해야 한다.

배포는 다음 순서로 진행한다.

1. `code-highlighting/README.md`의 고정 버전 빌드 또는
   `nix develop --command bash tests/run-anki-code-highlight-tests.sh`로 번들과 DOM 계약을 검사한다.
   `dist/manifest.json`의 JavaScript·라이선스를 신규 미디어로 저장하고 기기별 다운로드를 확인한다.
   기존 `_highlight.js`와 `_highlights.css`는 덮어쓰지 않는다.
2. 최신 `anki_model_info`로 `code_highlighting.build_plan(model, targets)`를 만든다.
   target은 `template_name`, `side`, `field_name`을 명시한다. 노트 유형·필드 범위를 추측하지 않는다.
   repo 밖에서 planner를 쓰면 `asset_filename`에 검증한 manifest의 파일명을 명시한다.
   변경 전에 원본 계획·필드·복구점을 확보하고 아래 구조 변경 승인·Upload 절차를 따른다.
3. `changes[].change`를 기존 `model_template_update`에 전달한다. 원복은 `changes[].original`이다.
   양쪽 모두 기대 모델 ID와 앞뒤 원문에 묶여 있으므로 나중에 수정된 내용을 덮어쓰지 않는다.
   알려진 구형 mobile Note Linker renderer는 코드 영역을 건너뛰는 버전으로 함께 바꾼다.
   미확인 renderer나 부분 설치는 거절한다. Mac에는 선언적 Note Linker 패키지의 동일 호환 패치를 적용한다.
4. 기존 코드의 언어 보완은 `build_field_patch(note_id, fields, languages_by_field)`로
   블록 순서별 명시적 언어 목록을 전달한다. 미디어·템플릿 준비 후 `change`를 필드 변경에 사용한다.
   이 함수는 언어 class와 기존 pre의 두 줄바꿈 style만 바꾸며, 읽은 필드와 기대값이 다르면 거절된다.
   `original`은 같은 조건으로 보호한 원복 입력이다. 내용을 임의 추정하거나 모호한 HTML을 고치지 않는다.
5. 호스트 readback과 Mac·iPhone의 앞뒤·야간 모드·오프라인 표시를 각각 확인한다.
   note/card ID, 일정, 복습 이력, 별표·검토 메모를 보존한다. 호스트 sync 성공만으로 기기 검증을 대신하지 않는다.

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
메모를 비울 때는 단일·일괄 필드 수정 모두 `expected_fields={"검토 메모": 마지막으로 읽은 전체 값}`을 함께 보낸다.
일괄 수정은 각 노트마다 해당 값을 넣으며, HTML·줄바꿈·끝부분을 자르거나 정규화하지 않는다.
사전 동기화 뒤 하나라도 값이 다르면 `expected-field-value-mismatch`로 전체 작업이 쓰기 전에 거절된다.
이때 메모와 별표를 유지하고 새 메모를 읽어 다시 확인받는다. 기대값 검사를 빼거나 새 내용으로 바꿔 자동 재시도하지 않는다.
둘 다 정리할 때는 메모를 비우고 결과를 확인한 뒤 별표를 해제한다. 일부 실패·결과 불명이면 상태를 재조회하고
남은 내용을 보고하며, 새 요청 번호로 전체 정리를 반복하지 않는다.
이는 기존 조회·필드 수정·태그 도구를 사용하는 LLM 지침이다. 서버가 대화의 완료·동의를 자동 판정하는 기능은 아니다.
기대값 검사는 호스트에 도착한 메모만 비교한다. 아직 다른 기기에서 동기화하지 않은 내용까지 확인하는 기능은 아니다.
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

## 관리 노트 유형: 기준·차이·제한 복구

초기 관리 대상은 **`CS 재활 Basic` 하나**다. 다른 유형은 `unmanaged`이며 자동 등록하지 않는다.
관리 원본은 [managed-types](managed-types/README.md)의 모델 정의·앞뒷면·CSS와 자산 목록이다.
필드/템플릿의 이름·설정·순서, 카드 생성 조건, 등록된 JS/CSS의 파일명과 실제 bytes를 관리한다.
개인 노트 본문·이미지·음성은 Git 원장에 넣지 않는다. 기존 기능 조각과 최종 템플릿의 일치는 생성·검증 과정에서 확인한다.

버전은 canonical schema 버전과 관리 내용의 **bundle digest**로 식별한다. Git SHA는 출처이며 권한이나 내용 버전이 아니다.
같은 내용을 squash/rebase하거나 무관한 파일을 바꿔도 업데이트로 판단하지 않는다. 운영 모델 ID·시각은 digest에서 제외하고,
인스턴스·컬렉션·실제 모델 ID 바인딩은 따로 검증한다. 이름이 같은 유형을 삭제 후 재생성해도 자동 채택하지 않는다.
비교·복구 기준은 **마지막으로 적용하고 검증한 등록본**이다. 최신 main에 다른 내용이 있어도 `업데이트 대기`일 뿐 drift는 아니다.
정의와 자산 bytes를 비공개 호스트 저장소에 보존하므로 GitHub 장애가 로컬 기준 자체를 무효화하지 않는다.
GitHub 최신본 확인 실패는 별도 상태로 보여 주며, 최신본을 자동 설치하거나 앱 내용을 Git 기준으로 자동 채택하지 않는다.

### 검사와 쓰기 보호

기존 호스트–AnkiWeb 동기화가 성공한 뒤와 `anki_managed_model_check` 요청 때 서버가 결정적으로 비교한다.
별도 상시 감시 데몬을 추가하지 않는다. `normal`/`drift`/`unavailable`과 관측 시각·호스트 동기화 경계·기준 버전을 확인한다.
기준 미등록·손상, 읽기 오류, 지원하지 않는 설정은 `unavailable`이다. 자산이 확실히 없으면 drift,
자산을 읽을 수 없는 경우는 unavailable로 구분한다. 검사 실패나 동기화 실패를 예전 정상 관측으로 덮지 않는다.
정상 결과도 **호스트에서 관측한 상태**이며, Mac/iPhone에서 아직 올리지 않은 변경이나 각 기기 화면을 확인했다는 뜻이 아니다.

관리 유형은 **최초 기준 등록 전에도 MCP 노트 추가·필드 쓰기가 차단**된다. drift/unavailable 동안 같은 보호를 유지한다.
실제 쓰기 직전 기존 mutation lock 안에서 유형과 자산을 다시 검사하며, 정기 검사 캐시만 믿고 쓰지 않는다.
차단 대상이 섞인 일괄 요청은 어떤 노트도 바꾸기 전에 전체 거절한다. 다른 유형을 먼저 처리하려면 요청을 분리한다.
읽기·다른 유형의 작업과 사용자의 Anki 앱 복습·수동 편집은 계속 가능하다. 보호를 피하려고 기준을 지우거나 임의 등록하지 않는다.

새 차이는 원본·상세 차이와 함께 비공개 사건으로 보존하고 Pushover에는 확인이 필요하다는 안내만 보낸다.
같은 미해결 차이는 재알림하지 않으며, 해결 뒤 재발하면 새 사건이다. 실제 수정 시각·기기·행위자를 추정하지 않는다.
`anki_managed_model_history`에서 기준, 마지막 정상, 최초 발견, 변경 항목, 해결 방식과 통지 상태를 확인한다.
통지는 `sent`/`failed`/`unknown`을 구분한다. 전송 중 종료도 unknown이며 중복 발송을 막기 위해 자동 재시도하지 않는다.
명확히 실패한 미해결 사건만 운영자가 `retry-notification`으로 재전송할 수 있다.
해결된 상세 이력은 **해결 시점부터 90일**, 미해결 이력은 해결 전까지 보존한다. 활성 기준·복구 자산과
멱등성·재개에 필요한 기록은 이 상세 이력 정리 대상이 아니다. 개인 원본과 상세 차이를 공개 이슈·알림 본문에 붙이지 않는다.

### 최초 등록과 운영자 명령

`nrs`가 코드를 배포했다는 이유만으로 현재 앱 상태를 승인된 기준으로 등록하지 않는다.
운영자는 공개 가능한 Git 원본과 실제 적용본의 일치, 백업, 같은 Anki 버전의 격리 복사본 검증 결과를 확인한 뒤 등록한다.
원본과 현재 상태가 다르면 먼저 원인을 검토한다. 새 버전의 최초 적용이나 앱 변경의 Git 반영은 별도 검토·적용 절차다.

```bash
sudo anki-host-managed-main inspect
sudo anki-host-managed-main enrollment-preview
# 반환된 대상·digest·복구점·보존 검증을 검토한 뒤, 해당 미리보기를 명시적으로 승인
sudo anki-host-managed-main register <operation_id> --preview-token <preview_token> --confirm
sudo anki-host-managed-main inspect
```

현재 관리 원장은 동기화 인스턴스인 `main`에만 설정하며, import 전용 `lab`에는 관리 명령을 설치하지 않는다.
`anki-host-managed-main`은 root 전용이며 wrapper가 지정한 인스턴스·loopback·역할 키만 쓴다.
`inspect`는 읽기 키, 등록·통지 재시도·복구 진단은 schema 키를 사용한다. 임의 URL·파일·원문·digest 입력이나
일반 schema 승인, 서비스 실행, 전체 Upload/Download를 받는 인자는 없다. 키와 상세 비공개 결과를 로그·PR에 복사하지 않는다.

```bash
sudo anki-host-managed-main retry-notification <incident_id>
sudo anki-host-managed-main diagnose-restore <request_id>
```

진단은 현재 bytes와 보존 결과를 다시 확인하며 변경을 반복 적용하지 않는다. 명령 종료 코드 0만으로 복구·전달 완료를 판단하지 말고
반환된 상태를 확인한다. 준비·실행 응답이 유실되면 원 요청 번호로 상태를 조회하고 새 번호로 변경을 반복하지 않는다.

### ChatGPT에서 제한 복구

1. GitHub 연결로 관리 기준 코드를 읽고 `anki_managed_model_check`와 필요하면 이력에서 현재 차이를 확인한다.
2. 복구 또는 앱 변경의 Git 반영 중 사용자의 선택을 받는다. 복구는 `anki_restore_managed_model`로 미리보기를 준비한다.
3. 대상·기준 버전·변경 범위·복구점·검증·만료를 사용자에게 보여 준 뒤, 같은 `request_id`와 `preview_token`,
   `confirm=true`로 확인을 제출한다. **LLM이 대화의 승인을 제출하는 방식이며 독립된 사람 인증 UI가 아니다.**
   확인은 미리보기를 만든 메시지가 아니라 사용자의 다음 메시지에서 제출해야 적용된다('ChatGPT 쓰기 확인').
4. `anki_managed_restore_status`로 결과를 재조회한다. `applied`는 검증된 로컬 복구,
   `sync.state=synced`는 별도로 검증한 AnkiWeb 컬렉션/필요 미디어 전달이다. 각 클라이언트 수신·화면 검증은 따로 한다.

서버가 적용·검증 이력에서 현재 허용된 기준과 실제 bytes를 고른다. 호출자는 새 기준·임의 digest·원문을 전달할 수 없다.
앞뒷면 HTML·CSS·등록된 JS/CSS만 대상이다. 필드 구조·템플릿 수·카드 생성 조건이 바뀌거나 보존을 확신할 수 없으면 중지한다.
HTML만 바뀌어도 카드가 생성될 수 있으므로 같은 버전의 Anki로 격리 복사본을 시험하고,
노트 본문·노트/카드 ID·일정·복습 기록·별표·메모를 **전체 전후 비교**한다. 개수만 같다고 안전하다고 보지 않는다.

준비 때 컬렉션 백업 외에 등록 자산의 직전 bytes 또는 부재 상태도 작업에 묶어 보존한다.
일반 미디어 API의 덮어쓰기 금지는 유지하며, 이 복구 전용 경로만 검증된 등록 파일을 다룬다.
경로 이탈·심볼릭 링크·미등록 파일은 거절한다. 확인 토큰은 현재 상태·대상·복구점·만료에 묶이며 상태가 바뀌면 다시 준비한다.
`partial`/`unknown`은 성공이나 재적용 지시가 아니다. 구성요소 상태와 복구점부터 진단한다.
로컬 전체 bytes와 데이터 보존을 확인하기 전에는 drift/쓰기 차단을 해제하지 않는다. 확인된 `applied`의 같은 요청 재호출은
필요한 전달만 재개하며, 클라이언트가 보낸 성공 영수증으로 전달 완료를 만들지 않는다.

전체 Upload가 필요하면 모든 관련 기기의 **새 사전 동기화 성공·복습/편집 중지**와 해당 작업의 Upload 승인을 확인한 뒤
기존 운영자 동기화 절차를 사용한다. 오래된 승인을 계속 재사용하거나 전체 Download를 자동 선택하지 않는다.
배포 확인은 서버/격리 테스트와 별도로 **실제 ChatGPT Chat의 기준 조회→차이 조회→대화 확인→허용 복구→상태 재조회**를 확인하고,
통제된 Mac·AnkiMobile에서 동기화 수신과 카드 ID 복사·노트 링크·코드 강조를 다시 확인한다.
확인하지 못한 연결·기기 구간은 미확인으로 남긴다. 이 문서에 절차가 있다는 사실은 배포나 실기기 검증 완료 증거가 아니다.
