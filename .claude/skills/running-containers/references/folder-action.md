# Immich FolderAction 자동 업로드 (macOS)

`~/FolderActions/upload-immich/`에 미디어 파일을 넣으면 Immich 서버에 자동 업로드.

## 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/darwin/programs/folder-actions/default.nix` | launchd agent + script 배포 |
| `modules/darwin/programs/folder-actions/files/scripts/upload-immich.sh` | 업로드 스크립트 |
| `secrets/immich-api-key.age` | Immich API 키 (agenix) |
| `secrets/pushover-immich.age` | Pushover 자격증명 (agenix) |

## 동작 플로우

파일 감지 → 안정화 대기 (5분 타임아웃) → 서버 ping → `bun x @immich/cli@3 upload --delete -- <미디어 목록>` → 남은 원본 서버 확인 (`bulk-upload-check`) → Pushover 알림

## 핵심 설계

- 업로드 대상: 확장자가 서버 v3.3.1이 받는 이미지·영상 목록(`MEDIA_EXT`, 출처는 스크립트 주석)에 든 파일만 안정화 뒤 확정한 목록으로 CLI에 넘긴다. 폴더를 통째로 넘기지 않으므로 대기 중에 새로 들어온 파일은 다음 실행에서 처리한다. `.ts`는 서버 목록대로 영상(MPEG-TS)으로 본다
- 비미디어 파일: 업로드 대상에 넣지 않는다. 미디어 없이 비미디어만 있으면 알림 없이 끝나고(알림 스팸 방지), 미디어와 섞여 있으면 시작 전 비미디어 중 실행 뒤에도 남은 수를 알림에 적는다. 예외로 업로드되는 원본과 이름이 맞는 `.xmp`(`<이름>.xmp`, `<파일>.xmp`)는 CLI가 사이드카로 함께 올리고 원본과 함께 지운다
- 원본 삭제 규칙: CLI의 `--delete`는 이번 실행에 업로드 응답을 받은 파일만 지운다. CLI는 일부 업로드가 실패해도 종료 코드 0으로 끝나므로 스크립트는 종료 코드만 보고 파일을 지우지 않는다
- 중복 처리: CLI의 `--delete-duplicates`는 쓰지 않는다. 서버 휴지통에만 있는 자산도 중복으로 보고 지우며, 올린 적 없는 `.xmp` 사이드카까지 함께 지우기 때문이다. 대신 CLI가 끝난 뒤 남은 원본의 SHA1을 스크립트가 `POST /api/assets/bulk-upload-check`로 확인해, `reject`/`duplicate`이고 `isTrashed=false`인 원본만 지운다(사이드카는 남긴다). 지우기 직전에 SHA1을 다시 구해 확인에 쓴 값과 다르면 남긴다. 휴지통 중복과 서버에 없는 파일(`accept`)은 남긴다. 확인 요청이 실패하거나 응답을 해석할 수 없으면(응답 `id`가 요청 순번과 정확히 같은 10진수가 아닌 경우 포함) 아무것도 지우지 않는다. API 키는 curl config로 stdin에 넘겨 명령줄과 로그에 남기지 않는다. CLI가 0이 아닌 코드로 끝나면 확인하지 않고 남은 원본을 모두 둔다
- 알림: CLI 종료 코드가 0이 아니면 실패(남은 수 포함). 0이면 서버 저장이 확인된 수(업로드 + 서버에 이미 있던 중복)로 나눈다: 전부이고 원본을 다 정리했으면 완료, 전부인데 서버에 있는 원본 삭제에 실패했으면 원본 정리 실패, 0개면 업로드된 파일 없음, 그 사이면 일부 미업로드. 남긴 원본은 사유별(서버에 있으나 삭제 실패, 업로드 안 됨, 서버 휴지통, 서버 확인 실패)로 센다
- CLI 버전: `@immich/cli@3`으로 메이저를 고정한다. 서버 이미지(`modules/nixos/programs/docker/immich.nix`의 immich-server)와 메이저가 같아야 하며, `test_upload_immich_cli_major_matches_server_image`가 이를 검사한다
- 업로드 실행 시간 제한 없음: launchd는 `TimeOut` 키를 구현하지 않는다. 멈춘 실행도 저장이 확인되지 않은 원본은 지우지 않으며, 그 프로세스를 끝내면 다음 실행이 stale lock을 회수한다
- 남은 제약 — 업로드 경합: CLI가 `bulk-upload-check`를 한 뒤 업로드하기 전에 다른 클라이언트가 같은 파일을 올리면, 서버가 업로드에 DUPLICATE로 답하고 `--delete`가 원본과 짝 `.xmp`를 지운다. 원본은 서버에 있지만 `.xmp`는 저장되지 않았을 수 있다
- 남은 제약 — 인자 길이: 미디어 목록을 CLI 인자로 넘기므로 ARG_MAX(macOS 1MiB, 경로 길이에 따라 대략 1만 개)를 넘으면 실행 자체가 실패한다(종료 코드 126). 그때는 원본을 모두 남기고 실패로 알리므로, 파일을 나눠 넣는다
- `IMMICH_INSTANCE_URL`: `https://<immich 서브도메인>.<기본 도메인>` (`constants.nix`의 `domain.subdomains.immich`·`domain.base`, launchd EnvironmentVariables). ping과 서버 확인도 이 주소의 `/api`를 쓴다

## 디버깅

```bash
# 로그 확인
tail -f ~/Library/Logs/folder-actions/upload-immich.log

# agent 상태
launchctl list | grep upload-immich

# 수동 실행 테스트
~/.local/bin/upload-immich.sh
```
