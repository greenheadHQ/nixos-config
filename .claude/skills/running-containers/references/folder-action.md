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

파일 감지 → 안정화 대기 (5분 타임아웃) → 서버 ping → `bun x @immich/cli@3 upload` (저장 확인된 원본 삭제) → Pushover 알림

## 핵심 설계

- 원본 삭제는 CLI만 한다: `--delete`는 업로드 응답을 받은 파일, `--delete-duplicates`는 서버에 이미 있는 파일을 지운다. CLI는 일부 업로드가 실패해도 종료 코드 0으로 끝나므로 스크립트는 종료 코드만 보고 파일을 지우지 않는다
- 데이터 손실 방지: 업로드 전에 미디어 목록을 기록하고, CLI 실행 뒤 그 목록에서 남은 원본 수를 센다. 업로드 실패·서버 미지원 형식·중복 확인 실패로 남은 원본은 보존한다
- 알림: 종료 코드 0이고 남은 원본이 없으면 완료, 종료 코드 0인데 남은 원본이 있으면 일부 미업로드(업로드 수/전체 수), 종료 코드가 0이 아니면 실패(남은 수 포함)
- CLI 버전: `@immich/cli@3`으로 메이저를 고정한다. 서버 이미지(`modules/nixos/programs/docker/immich.nix`의 immich-server)와 메이저를 맞춘다
- 업로드 실행 시간 제한 없음: launchd는 `TimeOut` 키를 구현하지 않는다. 멈춘 실행도 저장이 확인되지 않은 원본은 지우지 않으며, 그 프로세스를 끝내면 다음 실행이 stale lock을 회수한다
- `IMMICH_INSTANCE_URL`: `constants.nix`에서 IP/포트 자동 구성 (launchd EnvironmentVariables)
- 비미디어 파일: 미디어 없이 비미디어만 있으면 무시 (알림 스팸 방지)

## 디버깅

```bash
# 로그 확인
tail -f ~/Library/Logs/folder-actions/upload-immich.log

# agent 상태
launchctl list | grep upload-immich

# 수동 실행 테스트
~/.local/bin/upload-immich.sh
```
