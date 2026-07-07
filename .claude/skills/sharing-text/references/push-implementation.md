# push 함수 구현 상세

## 소스 위치

`push()` 함수 본문은 `modules/shared/programs/shell/default.nix`에 있습니다. Pushover 전송 구현은 `modules/shared/scripts/lib/pushover.sh`의 `pushover_send()`가 담당하며, Home Manager가 이 helper를 `$HOME/.local/lib/pushover.sh`로 배포합니다.

## 동작 요약

- 입력 텍스트는 인자, stdin, tmux buffer 순서로 선택합니다.
- credential 파일은 `$HOME/.config/pushover/share`를 사용합니다.
- helper 파일 `$HOME/.local/lib/pushover.sh`가 읽기 가능해야 하며, 없으면 즉시 실패합니다.
- helper를 `source`한 뒤 credential을 검증하고 `pushover_send "$cred" "📋 텍스트 공유 (${#text}자)" "$text" 0` 형태로 전송합니다.
- `curl` 호출 세부사항은 `push()`에 복사하지 않고 `pushover_send()` helper에 둡니다.

## 입력 우선순위

인자 > 파이프(stdin) > tmux buffer

## Credentials

- 경로: `$HOME/.config/pushover/share`
- 관리: agenix로 암호화
- 내용: `PUSHOVER_TOKEN`, `PUSHOVER_USER` 환경변수

## 에러 처리

| 상황 | 메시지 | 출력 |
|------|--------|------|
| 입력 없음 | `Usage: push <text> or pipe input` | stdout |
| credential 파일 없음 | `Error: Pushover credentials not found` | stderr |
| helper 파일 없음 | `Error: Pushover helper not found` | stderr |
| token/user 비어있음 | `Error: Pushover credentials are incomplete` | stderr |
| helper 전송 실패 | `Error: Pushover 전송 실패` | stderr |
