---
name: hosting-copyparty
description: |
  This skill should be used when the user asks about Copyparty file server,
  "파일 서버", "copyparty", "파일 공유", "HDD 웹 접근", "WebDAV",
  "Google Drive 대체", "파일 업로드", "파일 다운로드",
  "copyparty 설정", "copyparty 로그인", "copyparty 포트",
  or encounters Copyparty container issues, ACL permission problems,
  config generation failures, password injection issues.
---

# Copyparty 파일 서버 관리

HDD(`/mnt/data`) 전체를 웹 브라우저로 탐색/업로드/다운로드하는 셀프호스팅 파일 서버입니다.
Podman 컨테이너로 실행되며, Tailscale VPN 내에서만 접근 가능합니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `copyparty` mkOption 정의 |
| `modules/nixos/programs/docker/copyparty.nix` | Podman 컨테이너 + 설정 생성 서비스 |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `secrets/copyparty-password.age` | agenix 암호화 비밀번호 |
| `libraries/constants.nix` | 포트 (`copyparty = 3923`), 리소스 제한 |

## 빠른 참조

### 접근 방법

| 방식 | URL |
|------|-----|
| 웹 UI | `http://100.79.80.95:3923` |
| WebDAV (Mac Finder) | 서버에 연결 > `http://100.79.80.95:3923` |

로그인: `greenhead` / 비밀번호: agenix secret

### 서비스 관리

```bash
podman ps | grep copyparty                    # 컨테이너 상태
podman logs copyparty                         # 로그 확인
systemctl status podman-copyparty             # systemd 서비스 상태
systemctl status copyparty-config             # 설정 생성 서비스 상태
journalctl -u podman-copyparty -f             # 로그 실시간
curl -I http://100.79.80.95:3923              # HTTP 응답 확인
```

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.copyparty.enable = true;   # 활성화
homeserver.copyparty.port = 3923;     # 포트 (기본값은 constants.nix)
```

### ACL 구조

현재 단일 루트 볼륨으로 HDD 전체를 rwda(읽기/쓰기/삭제/관리) 권한으로 제공합니다.

| Copyparty 경로 | 호스트 경로 | 권한 |
|----------------|------------|------|
| `/` | `/mnt/data` | 읽기/쓰기/삭제/관리 |

> **주의**: Immich 사진(`/immich/`)이나 Anki 백업(`/backups/`)을 Copyparty에서 삭제하지 않도록 주의.
> Copyparty에서 Immich 파일 삭제 시 Immich DB와 불일치 발생.

**경로별 읽기 전용 ACL 불가 이유**: Copyparty는 루트 `/` -> `/data` 마운트 시 하위 경로(`/data/immich`)를
자동으로 `/immich`에 서빙하므로, `[/immich]` 섹션으로 별도 마운트하면 "multiple filesystem-paths" 충돌 발생.
상세: [references/troubleshooting.md](references/troubleshooting.md) 항목 6 참조.

### 설정 파일 구조

설정 파일(`copyparty.conf`)은 `copyparty-config` oneshot 서비스가 agenix 시크릿에서 비밀번호를 주입하여 생성합니다.
위치: `/var/lib/docker-data/copyparty/config/copyparty.conf` (chmod 0600)

## 스토리지 구조

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/var/lib/docker-data/copyparty/hists` | SSD | DB/인덱스/썸네일 캐시 |
| `/var/lib/docker-data/copyparty/config` | SSD | 설정 파일 (0700) |
| `/mnt/data` | HDD | 전체 파일 저장소 |

## Known Issues

**ENTRYPOINT 오버라이드 필수**
- `copyparty/ac` 이미지의 ENTRYPOINT가 `-c /z/initcfg`로 내장 설정을 로드
- initcfg의 `% /cfg` 라인이 루트 `/`에 볼륨 마운트 → 우리 `[/]` 설정과 충돌
- 해결: `--entrypoint=python3`로 오버라이드하여 initcfg 건너뛰기
- `cmd`에 `-m copyparty -c /cfg/config.conf` 전달
- initcfg의 `no-crt` 설정을 우리 config의 `[global]`에 직접 포함 필요

**경로별 읽기 전용 ACL 불가**
- Copyparty는 루트 볼륨 `[/]` -> `/data`가 이미 `/data/immich`을 `/immich`으로 서빙
- `[/immich]` -> `/data/immich` 별도 선언 시 "multiple filesystem-paths mounted at [/immich]" 에러
- 동일 가상 경로에 두 개의 파일시스템 경로 매핑 불가
- 결론: 단일 루트 볼륨만 사용, 하위 경로 보호는 사용자 주의에 의존

**비밀번호 주입 방식**
- Copyparty는 `PASSWORD_FILE` 환경변수 미지원
- `copyparty-config` oneshot 서비스가 quoted heredoc + `printf '%s'`로 안전 주입
- 비밀번호에 `$`, `` ` ``, `\` 등 특수문자가 있어도 안전

**ConditionPathExists 안전장치**
- 설정 파일이 없으면 컨테이너 시작 방지
- Podman이 존재하지 않는 파일을 마운트 시 디렉토리로 생성하는 문제 예방

**Tailscale IP 바인딩 타이밍**
- 부팅 시 Tailscale IP 할당 전에 컨테이너 시작하면 바인딩 실패
- 해결: `tailscale-wait.nix`로 60초 대기

**썸네일 캐시**
- `th-maxage: 7776000` (90일) 설정
- 캐시 위치: SSD (`/var/lib/docker-data/copyparty/hists`)
- `th-maxsize` 옵션은 존재하지 않음 (사용 금지)

**이미지 태그**
- `copyparty/ac:latest` 사용 (audio/video/image 썸네일 + 트랜스코딩 포함)
- 기본 `copyparty/copyparty` 이미지는 썸네일 미지원

## 자주 발생하는 문제

1. **컨테이너 시작 실패**: `journalctl -u podman-copyparty`에서 "multiple filesystem-paths" 또는 initcfg 충돌 확인. 상세: troubleshooting 항목 6, 7
2. **로그인 실패**: agenix secret 복호화 확인 (`sudo cat /run/agenix/copyparty-password`)
3. **IP 바인딩 실패**: Tailscale VPN 연결 확인, `tailscale-wait.nix` import 확인
4. **비밀번호 변경**: `agenix -e secrets/copyparty-password.age` 후 `nrs` 재적용

## 레퍼런스

- 설치/설정 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
