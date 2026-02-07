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

파일 감지 → 안정화 대기 (5분 타임아웃) → 서버 ping → `bunx @immich/cli upload` → Pushover 알림 → 원본 삭제

## 핵심 설계

- **`--delete` 버그 대응**: CLI는 중복 파일을 삭제하지 않음. 사전 기록한 미디어 목록 기반으로 수동 삭제
- **데이터 손실 방지**: 업로드 전에 파일 목록을 배열에 기록, 완료 후 해당 파일만 삭제
- **launchd TimeOut 1800초**: `bunx` 업로드 무한 대기 방지. PID 기반 stale lock으로 강제 종료 후 자동 복구
- **`IMMICH_INSTANCE_URL`**: `constants.nix`에서 IP/포트 자동 구성 (launchd EnvironmentVariables)
- **비미디어 파일**: 미디어 없이 비미디어만 있으면 무시 (알림 스팸 방지)

## 디버깅

```bash
# 로그 확인
tail -f ~/Library/Logs/folder-actions/upload-immich.log

# agent 상태
launchctl list | grep upload-immich

# 수동 실행 테스트
~/.local/bin/upload-immich.sh
```
