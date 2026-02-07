# 모바일 SSH에서 Claude Code로 이미지 전달

모바일 SSH 환경(Termius 등)에서 클립보드 이미지 붙여넣기가 불가능할 때 Immich를 활용하여 이미지를 전달하는 방법입니다.

## 핵심 원리

| 도구 | 실행 위치 | Tailscale IP 접근 |
|------|-----------|-------------------|
| WebFetch | Anthropic 서버 | 불가 |
| Read | MiniPC 로컬 | 파일 경로로 가능 |

WebFetch는 Anthropic 서버에서 실행되어 Tailscale 내부 IP에 접근 불가하지만, Read는 로컬에서 실행되어 **파일 경로**로 이미지를 읽을 수 있습니다.

## 워크플로우

```
[iPhone]
사진 공유 → Scriptable "Upload to Claude Code" → 경로 클립보드 복사

[MiniPC SSH]
경로 붙여넣기 → Claude Code Read 도구로 이미지 확인

[자동화]
매일 07:00 KST "Claude Code Temp" 앨범 전체 삭제 + Pushover 알림
```

## 경로 변환 (중요)

Immich API가 반환하는 `originalPath`:
```
/usr/src/app/upload/upload/UUID/xx/xx/file.png
```

호스트에서 접근 가능한 경로:
```
/var/lib/docker-data/immich/upload-cache/UUID/xx/xx/file.png
```

**변환 규칙**: `/usr/src/app/upload/upload/` → `/var/lib/docker-data/immich/upload-cache/`

## 상세 설정

- Scriptable 스크립트: [scriptable-immich-upload.md](scriptable-immich-upload.md)
- 자동 삭제 설정: `homeserver.immichCleanup.enable = true`

## macOS에서 immich 사진 확인

macOS 환경에서 immich 사진 경로를 받았을 때는 `viewing-immich-photo` 스킬 참조.
SSH로 MiniPC에서 파일을 가져와 로컬에서 Read 도구로 확인합니다.
