---
name: viewing-immich-photo
description: |
  Immich photo viewer: resolve photo paths, display images.
  Triggers: "view immich photo", "이미치 사진 확인", "immich 파일 보여줘",
  "immich 사진 보여줘", paths containing "/var/lib/docker-data/immich/upload-cache"
  or "/var/lib/docker-data/immich".
---

# Immich 사진 확인

macOS 또는 NixOS 환경에서 immich 사진 경로를 받아 이미지를 확인하는 방법입니다.

## 목적과 범위

Immich 저장 경로 검증, 플랫폼별 파일 접근, 이미지 표시 절차를 다룬다.

## 빠른 참조

| 항목 | 값 |
|------|----|
| 허용 루트 | `/var/lib/docker-data/immich/upload-cache/`, `/var/lib/docker-data/immich/` |
| macOS 동작 | `ssh minipc`로 파일을 `/tmp` 복사 후 확인 |
| NixOS 동작 | 로컬 경로를 직접 확인 |
| 비허용 패턴 | `..` 포함 경로 |

## 경로 검증 (보안)

요청된 경로가 immich 디렉토리 내부인지 먼저 확인:
- 허용 경로: `/var/lib/docker-data/immich/upload-cache/` 또는 `/var/lib/docker-data/immich/`
- `..` 포함 경로는 거부 (path traversal 방지)

## 플랫폼 감지

환경 정보에서 플랫폼 확인:
- `<env>` 블록의 `Platform: darwin` → macOS
- `<env>` 블록의 `Platform: linux` → NixOS

## macOS에서 실행 시

MiniPC에 저장된 파일이므로 SSH로 가져온 후 Read 도구로 확인합니다.

### 핵심 절차

1. 경로가 `/var/lib/docker-data/immich/upload-cache`로 시작하는지 확인
2. SSH로 파일을 `/tmp`에 복사 (확장자 유지)
3. Read 도구로 이미지 확인
4. 삭제 불필요 (`/tmp`는 시스템 자동 정리)

### 명령어

```bash
# 파일명에서 확장자 추출 (Scriptable 업로드는 일반적으로 .jpg)
BASENAME="${FILE_PATH##*/}"
if [[ "$BASENAME" != *.* ]]; then
  echo "오류: 파일 확장자가 없습니다 (.jpg/.jpeg/.png/.webp/.gif 필요)." >&2
  exit 1
fi

EXT="${BASENAME##*.}"
case "$EXT" in
  jpg|jpeg|png|webp|gif|JPG|JPEG|PNG|WEBP|GIF) ;;
  *)
    echo "오류: 지원하지 않는 확장자: $EXT" >&2
    exit 1
    ;;
esac

ssh minipc "cat <원본경로>" > "/tmp/immich_photo_$(date +%s).$EXT"
```

**주의**: `minipc`는 SSH config에 정의된 호스트 alias.

## NixOS에서 실행 시

로컬 파일이므로 경로를 직접 Read 도구에 전달합니다.

### 핵심 절차

1. 경로 검증 규칙(허용 루트, `..` 부재)을 먼저 확인
2. 로컬 경로를 Read 도구에 직접 전달

## 경로 패턴

| 유형 | 경로 패턴 |
|------|----------|
| 업로드 캐시 | `/var/lib/docker-data/immich/upload-cache/UUID/xx/xx/file.ext` |
| 라이브러리 | `/var/lib/docker-data/immich/library/UUID/YYYY/MM/file.ext` |

## 경로 변환 (Immich API → 호스트)

| Immich API 경로 | 호스트 경로 |
|-----------------|-------------|
| `/usr/src/app/upload/upload/` | `/var/lib/docker-data/immich/upload-cache/` |

## 지원 파일 형식

Read 도구는 이미지를 시각적으로 표시:
- 이미지: `.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`
- 동영상: 확인 불가 (메타데이터만 표시)

**참고**: Scriptable 업로드는 항상 `.jpg`로 저장됨

## 트러블슈팅

| 상황 | 대응 |
|------|------|
| SSH 연결 실패 | `tailscale status` 확인, `ssh minipc "echo ok"` 테스트 |
| 파일 없음 | 경로 오타 확인, Immich API 경로→호스트 경로 변환 확인 |
| 권한 없음 | 파일 소유자/권한 확인 (`ls -la <path>`) |

## 참조

- Immich 경로 변환 규칙은 본 문서의 경로 패턴/변환 표를 기준으로 유지한다.
- 로컬 원본 기준: `modules/nixos/programs/docker/immich.nix`의
  `virtualisation.oci-containers.containers.immich-server.volumes`
  (`.../immich/photos:/usr/src/app/upload`,
  `.../immich/upload-cache:/usr/src/app/upload/upload`)
- 업스트림 기준: Immich 배포 템플릿 `docker/docker-compose.yml`의 `immich-server.volumes`
  (https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml)
