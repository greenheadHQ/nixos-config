---
name: viewing-immich-photo
description: |
  View immich photos: container→host path conversion, image display.
  Trigger: 'immich 사진 보여줘', 'immich 파일 보여줘', 'immich 사진 경로', 'upload-cache 파일 확인'.
  NOT for immich 컨테이너 관리 (use running-containers).
---

# Immich 사진 확인

macOS 또는 NixOS 환경에서 immich 사진 경로를 받아 이미지를 확인하는 방법입니다.

## 목적과 범위

Immich 저장 경로 검증, 플랫폼별 파일 접근, 이미지 표시 절차를 다룬다.

## 빠른 참조

| 항목 | 값 |
|------|----|
| 허용 루트 | `/mnt/data/immich/photos/`, `/var/lib/docker-data/immich/upload-cache/` |
| macOS 동작 | `scp minipc:…`로 staging 후 이미지 표시 도구로 표시 (비이미지는 SSH 원격에서 `file --`) |
| NixOS 동작 | 로컬 경로를 이미지 표시 도구에 직접 전달 (비이미지는 로컬 `file --`) |
| 비허용 패턴 | `..` 포함 경로 |

## 용어 binding

본문은 도구-중립 용어를 쓴다. 런타임별 실제 도구는 아래 표로 binding한다.

| 용어 | Claude Code | Codex |
|------|-------------|-------|
| 이미지 표시 도구 | `Read` 도구 | `view_image` 도구 |
| 비이미지 메타데이터 명령 | 공통 셸 `file -- <path>` | 공통 셸 `file -- <path>` |

**이미지 표시**는 런타임 분기, **메타데이터 명령**은 파일 형식 분기다 — 같은 축으로 섞지 않는다.
**비이미지 메타데이터 명령의 실행 위치**는 호스트 플랫폼에 따라 다르다: macOS는 SSH 원격에서 실행, NixOS는 로컬에서 실행 (상세는 아래 macOS/NixOS 섹션 참조).

## 경로 검증 (보안)

요청된 경로가 immich 디렉토리 내부인지 먼저 확인:
- 허용 경로: `/mnt/data/immich/photos/` 또는 `/var/lib/docker-data/immich/upload-cache/`
- `..` 포함 경로는 거부 (path traversal 방지)

## 플랫폼 감지

**로컬 호스트 기준**으로 판별한다. SSH 원격 `uname`은 사용하지 않는다 — MiniPC 안의 OS는 항상 Linux이므로 분기에 무의미하다.

| 우선순위 | 신호 | 출처 |
|----------|------|------|
| 1 | `<env>` 블록의 `Platform: darwin` / `Platform: linux` | Claude Code 하네스 메타 (Claude Code 한정) |
| 2 | 로컬 셸 `uname -s` 결과 (`Darwin` / `Linux`) | 양 런타임 공통 |

`<env>` 블록이 있으면 우선 사용, 없거나 불명확하면 로컬 셸에서 `uname -s`를 실행한다.

## macOS에서 실행 시

MiniPC에 저장된 파일이므로 이미지는 SSH로 staging한 뒤 이미지 표시 도구로 표시하고, 비이미지는 SSH 원격에서 `file`로 메타데이터만 가져옵니다.

### 핵심 절차

1. 위 "허용 루트" 표 기준으로 경로 검증 (`/mnt/data/immich/photos/` 또는 `/var/lib/docker-data/immich/upload-cache/`로 시작 + `..` 부재, path traversal 차단)
2. 확장자 분기:
   - **이미지** (`.jpg/.jpeg/.png/.webp/.gif`): `scp`로 `/tmp`에 staging → 이미지 표시 도구로 표시
   - **비이미지** (동영상/문서 등): 원격 셸에 단일 command string으로 `file --`을 보내 메타데이터만 출력 (staging 불필요). 명령 형식은 아래 명령어 블록 참조.
3. `/tmp`는 시스템 자동 정리 (수동 삭제 불필요)

### 명령어

```bash
# 사전 검증된 원본 경로 (허용 루트 + ".." 부재 통과 후 변수에 담는다)
FILE_PATH="<검증 통과한 원본경로>"
BASENAME="${FILE_PATH##*/}"
EXT="${BASENAME##*.}"
# 확장자 없거나 ($BASENAME == $EXT) 비이미지 확장자면 메타데이터 fallback으로 보낸다
case "$BASENAME" in
  *.jpg|*.jpeg|*.png|*.webp|*.gif|*.JPG|*.JPEG|*.PNG|*.WEBP|*.GIF)
    DEST="/tmp/immich_photo_$(date +%s).$EXT"
    scp -- "minipc:${FILE_PATH}" "$DEST"
    # 이후 이미지 표시 도구에 "$DEST"를 전달
    ;;
  *)
    # 비이미지 fallback — 원격 셸에 단일 command string으로 전달.
    # `ssh host arg...`는 arguments를 공백으로 join해 원격 셸이 재파싱하므로,
    # 로컬에서 미리 shell-quote(`printf '%q'`, bash/zsh 공통)해야 메타문자가 보존된다.
    ssh minipc "file -- $(printf '%q' "$FILE_PATH")"
    ;;
esac
```

**보안**: `<원본경로>` 같은 placeholder를 명령 문자열에 직접 삽입하지 마라.
- `scp` 같은 로컬 명령에는 검증 통과한 변수를 quote(`"${FILE_PATH}"`)와 `--` end-of-options 구분자로 전달한다.
- `ssh host cmd args`는 args를 공백으로 join해 원격 셸이 다시 파싱하므로, 로컬 quoting만으로 원격 셸 인자 경계가 보존되지 않는다. `printf '%q'`로 미리 quote해 단일 command string을 만들어 전달한다 (위 fallback 예시 참조).

**주의**: `minipc`는 SSH config에 정의된 호스트 alias.

## NixOS에서 실행 시

로컬 파일이므로 이미지는 경로를 직접 이미지 표시 도구에 전달하고, 비이미지는 로컬 `file`로 메타데이터만 출력합니다.

### 핵심 절차

1. 경로 검증 규칙(허용 루트, `..` 부재)을 먼저 확인
2. 확장자 분기:
   - **이미지** (`.jpg/.jpeg/.png/.webp/.gif`): 로컬 경로를 이미지 표시 도구에 직접 전달
   - **비이미지**: `file -- "${FILE_PATH}"`로 메타데이터 출력

## 경로 패턴

| 유형 | 경로 패턴 |
|------|----------|
| 업로드 캐시 | `/var/lib/docker-data/immich/upload-cache/UUID/xx/xx/file.ext` |
| 라이브러리 | `/mnt/data/immich/photos/library/UUID/YYYY/MM/file.ext` |

## 경로 변환 (Immich API → 호스트)

| Immich API 경로 | 호스트 경로 |
|-----------------|-------------|
| `/usr/src/app/upload/upload/` | `/var/lib/docker-data/immich/upload-cache/` |
| `/usr/src/app/upload/` | `/mnt/data/immich/photos/` |

## 지원 파일 형식

이미지 표시 도구는 이미지를 시각적으로 표시한다 (런타임 매핑은 위 "용어 binding" 표 참조):
- 이미지: `.jpg`, `.jpeg`, `.png`, `.webp`, `.gif`
- 비이미지 (동영상/문서 등): `file -- <path>`로 메타데이터만 출력 (시각적 표시는 불가)

**참고**: Scriptable 업로드는 항상 `.jpg`로 저장됨

## 트러블슈팅

| 상황 | 대응 |
|------|------|
| SSH 연결 실패 | `tailscale status` 확인, `ssh minipc "echo ok"` 테스트 |
| 파일 없음 | 경로 오타 확인, Immich API 경로→호스트 경로 변환 확인 |
| 권한 없음 | 파일 소유자/권한 확인 (`ls -la <path>`) |
| 외부 전제조건 | `minipc`/`mac`은 SSH config alias, MiniPC는 Tailscale 도달 가정. SSH/Tailscale 가용성은 본 스킬 범위 밖 — `managing-ssh` 스킬 참조. |

## 참조

- Immich 경로 변환 규칙은 본 문서의 경로 패턴/변환 표를 기준으로 유지한다.
- 로컬 원본 기준: `modules/nixos/programs/docker/immich.nix`의
  `virtualisation.oci-containers.containers.immich-server.volumes`
  (`.../immich/photos:/usr/src/app/upload`,
  `.../immich/upload-cache:/usr/src/app/upload/upload`)
- 업스트림 기준: Immich 배포 템플릿 `docker/docker-compose.yml`의 `immich-server.volumes`
  (https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml)
