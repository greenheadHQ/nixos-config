---
name: hosting-copyparty
description: |
  Manage Copyparty file server: status, config, troubleshooting, updates, ACL.
  Trigger: 'copyparty', 'copyparty-update', 'copyparty.greenhead.dev', '파일 서버', 'WebDAV',
  'Finder에서 서버', '업로드 서비스'.
  NOT for 컨테이너/Podman 일반 관리 (use running-containers). NOT for agenix 시크릿 일반 (use managing-secrets).
---

# Copyparty 파일 서버 관리

HDD(`/mnt/data`) 전체를 웹 브라우저로 탐색/업로드/다운로드하는 셀프호스팅 파일 서버입니다.
Podman 컨테이너로 실행되며, Caddy HTTPS 리버스 프록시(`https://copyparty.greenhead.dev`)를 통해 Tailscale VPN 내에서 접근합니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `copyparty` + `copypartyUpdate` mkOption 정의 |
| `modules/nixos/programs/docker/copyparty.nix` | Podman 컨테이너 + 설정 생성 서비스 |
| `modules/nixos/programs/copyparty-update/` | 버전 체크 + 수동 업데이트 자동화 |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 (Copyparty 포함) |
| `secrets/copyparty-password.age` | agenix 암호화 비밀번호 |
| `secrets/pushover-copyparty.age` | 업데이트 알림용 Pushover credentials |
| `libraries/constants.nix` | 포트 (`copyparty = 3923`), 리소스 제한 |

## 빠른 참조

### 접근 방법

| 방식 | URL |
|------|-----|
| 웹 UI | `https://copyparty.greenhead.dev` |
| WebDAV (Mac Finder) | 서버에 연결 > `https://copyparty.greenhead.dev` |
| 내부 (localhost) | `http://127.0.0.1:3923` (Caddy → localhost) |

로그인: `greenhead` / 비밀번호: agenix secret

### 서비스 관리

```bash
podman ps | grep copyparty                    # 컨테이너 상태
podman logs copyparty                         # 로그 확인
systemctl status podman-copyparty             # systemd 서비스 상태
systemctl status copyparty-config             # 설정 생성 서비스 상태
journalctl -u podman-copyparty -f             # 로그 실시간
curl -I https://copyparty.greenhead.dev        # HTTPS 응답 확인
curl -I http://127.0.0.1:3923                 # localhost 직접 확인
```

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.copyparty.enable = true;          # 컨테이너 활성화
homeserver.copyparty.port = 3923;            # 포트 (기본값은 constants.nix)
homeserver.copypartyUpdate.enable = true;    # 버전 체크 + 업데이트 알림 (04:00)
```

### Copyparty 업데이트

`homeserver.copypartyUpdate.enable = true`로 활성화. 매일 04:00에 GitHub Releases API로 최신 버전 확인 후 Pushover 알림.

```bash
sudo copyparty-update --dry-run   # 수행 예정 작업 확인
sudo copyparty-update             # 실제 업데이트 (pull → digest 비교 → 재시작 → 헬스체크)
```

- pinned tag 기준: 설정된 이미지를 pull → digest 비교 (같은 태그의 재빌드만 반영). GitHub latest는 알림/안내용
- 새 버전 반영은 `modules/nixos/programs/docker/copyparty.nix`의 image 태그 수정 후 `nrs`
- 백업 불필요 (설정은 Nix 관리, 데이터는 HDD 볼륨)
- ERR trap에서 컨테이너 자동 복구
- 통합 업데이트 시스템 상세: `running-containers` 스킬의 [service-update-system.md](../running-containers/references/service-update-system.md) 참조

### ACL 구조

현재 단일 루트 볼륨으로 HDD 전체를 rwmda(읽기/쓰기/이동/삭제/관리) 권한으로 제공합니다.
`m`(move)이 빠지면 웹 UI에서 파일 이름 변경/이동이 조용히 사라지므로, config 재작성 시 누락 금지.
정본: `modules/nixos/programs/docker/copyparty.nix`의 `accs:` 블록.

| Copyparty 경로 | 호스트 경로 | 권한 |
|----------------|------------|------|
| `/` | `/mnt/data` | 읽기/쓰기/이동/삭제/관리 |

> 주의: Immich 사진(`/immich/`)을 Copyparty에서 삭제하지 않도록 주의.
> Copyparty에서 Immich 파일 삭제 시 Immich DB와 불일치 발생.

경로별 읽기 전용 ACL 불가 이유: Copyparty는 루트 `/` -> `/data` 마운트 시 하위 경로(`/data/immich`)를
자동으로 `/immich`에 서빙하므로, `[/immich]` 섹션으로 별도 마운트하면 "multiple filesystem-paths" 충돌 발생.
상세: [references/troubleshooting.md](references/troubleshooting.md) 항목 6 참조.

### 설정 파일 구조

설정 파일(`copyparty.conf`)은 `copyparty-config` oneshot 서비스가 agenix 시크릿에서 비밀번호를 주입하여 생성합니다.
위치: `/var/lib/docker-data/copyparty/config/copyparty.conf` (chmod 0600)

이 파일은 서비스가 매 시작마다 재생성하므로 직접 편집하면 되돌아갑니다.
설정 변경은 `modules/nixos/programs/docker/copyparty.nix`의 `configScript`에서 하고 `nrs`로 반영합니다.

### 검색 인덱싱

`[global]`의 `e2dsa`가 파일 검색(웹 UI 상단 🔎 버튼)을 활성화합니다. 이 옵션이 없으면 버튼 자체가 표시되지 않습니다.
인덱스 DB는 `hist:` 경로(SSD)에 저장됩니다.

| 옵션 | 값 | 의미 |
|------|-----|------|
| `e2dsa` | (플래그) | 모든 볼륨을 시작 시 스캔하여 up2k DB에 색인 |
| `no-hash` | `.` | 정규식이며 `.`은 모든 경로에 매칭 — 스캔 시 파일 해시 계산 생략 |
| `re-maxage` | `86400` | 하루 1회 재스캔 (Copyparty 밖에서 추가된 파일 반영) |

`no-hash`로 해시를 생략해도 검색(파일명·경로·크기·날짜)은 정상 동작하며, 대신 업로드 시 중복 감지와
이어받기가 동작하지 않습니다. HDD 전체를 읽어야 하는 초기 해시 스캔을 피해 다른 서비스와의 디스크 경합을
줄이려는 선택입니다. 해시가 필요해지면 `no-hash` 줄을 제거하고 `nrs`로 재스캔합니다 (전체 읽기로 장시간 소요).

`e2dsa`는 컨테이너 시작 시점에만 스캔하므로, 백업 스크립트나 Immich처럼 Copyparty 밖에서 파일을 추가하는
경로가 있으면 `re-maxage` 없이는 인덱스가 낡습니다.

## 스토리지 구조

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/var/lib/docker-data/copyparty/hists` | SSD | DB/인덱스/썸네일 캐시 |
| `/var/lib/docker-data/copyparty/config` | SSD | 설정 파일 (0700) |
| `/var/lib/docker-data/copyparty/sessions` | SSD | 세션 DB/salt/iphash (0700) |
| `/mnt/data` | HDD | 전체 파일 저장소 |

## Known Issues

ENTRYPOINT 오버라이드 필수
- `copyparty/ac` 이미지의 ENTRYPOINT가 `-c /z/initcfg`로 내장 설정을 로드
- initcfg의 `% /cfg` 라인이 루트 `/`에 볼륨 마운트 → 우리 `[/]` 설정과 충돌
- 해결: `--entrypoint=python3`로 오버라이드하여 initcfg 건너뛰기
- `cmd`에 `-m copyparty -c /cfg/config.conf` 전달
- initcfg의 `no-crt` 설정을 우리 config의 `[global]`에 직접 포함 필요

경로별 읽기 전용 ACL 불가
- Copyparty는 루트 볼륨 `[/]` -> `/data`가 이미 `/data/immich`을 `/immich`으로 서빙
- `[/immich]` -> `/data/immich` 별도 선언 시 "multiple filesystem-paths mounted at [/immich]" 에러
- 동일 가상 경로에 두 개의 파일시스템 경로 매핑 불가
- 결론: 단일 루트 볼륨만 사용, 하위 경로 보호는 사용자 주의에 의존

비밀번호 주입 방식
- Copyparty는 `PASSWORD_FILE` 환경변수 미지원
- `copyparty-config` oneshot 서비스가 quoted heredoc + `printf '%s'`로 안전 주입
- 비밀번호에 `$`, `` ` ``, `\` 등 특수문자가 있어도 안전

ConditionPathExists 안전장치
- 설정 파일이 없으면 컨테이너 시작 방지
- Podman이 존재하지 않는 파일을 마운트 시 디렉토리로 생성하는 문제 예방

리버스 프록시 (Caddy) 뒤에서 CORS 403
- Caddy 리버스 프록시를 통해 접근 시 `rejected by cors-check` 에러 발생
- 해결: `[global]` 섹션에 `rproxy: 1` + `xff-src: 10.88.0.0/16` (constants.network.podmanSubnet, Podman 브릿지 네트워크) 추가
- `rproxy: 1`만으로는 부족 — X-Forwarded-For 헤더 소스(Podman gateway)를 `xff-src`로 신뢰해야 함
- 설정 변경 후 컨테이너 재시작 필수 (`sudo systemctl restart podman-copyparty`)

localhost 바인딩 (Caddy 연동)
- 포트가 `127.0.0.1:3923`에 바인딩 (Caddy가 유일한 외부 진입점)
- Tailscale IP 바인딩/tailscale-wait.nix 불필요 (localhost는 항상 사용 가능)

썸네일 캐시
- `th-maxage: 7776000` (90일) 설정
- 캐시 위치: SSD (`/var/lib/docker-data/copyparty/hists`)
- `th-maxsize` 옵션은 존재하지 않음 (사용 금지)

이미지 태그
- `copyparty/ac` variant를 pinned tag로 사용 (audio/video/image 썸네일 + 트랜스코딩 포함)
- 실제 태그 정본: `modules/nixos/programs/docker/copyparty.nix` (재검증: `rg -n 'image = ' modules/nixos/programs/docker/copyparty.nix`)
- 기본 `copyparty/copyparty` 이미지는 썸네일 미지원

세션 데이터 영속성
- CopyParty는 세션 DB(`sessions.db`)와 인증 salt(`ah-salt.txt`, `dk-salt.txt`, `fk-salt.txt`), `iphash`를 `/cfg/copyparty/`에 저장
- 이 경로가 볼륨 마운트되지 않으면 컨테이너 재시작 시 세션 유실 → 403 에러
- 해결: `${dockerData}/copyparty/sessions:/cfg/copyparty` 볼륨 마운트 (0700)
- 세션 문제 발생 시 `sessions/` 디렉토리 내용을 비우고 재시작하면 초기화됨

## 자주 발생하는 문제

1. 컨테이너 시작 실패: `journalctl -u podman-copyparty`에서 "multiple filesystem-paths" 또는 initcfg 충돌 확인. 상세: troubleshooting 항목 6, 7
2. 로그인 실패: agenix secret 복호화 확인 (`sudo cat /run/agenix/copyparty-password`)
3. CORS 403 (리버스 프록시): `rproxy: 1` + `xff-src: 10.88.0.0/16` (constants.network.podmanSubnet) 설정 확인, 컨테이너 재시작
4. 비밀번호 변경: `(cd secrets && agenix -e copyparty-password.age)` 후 `nrs` 재적용

## 런타임 환경 전제

공통 NixOS MiniPC 호스트 전제는 [`../managing-minipc/references/host-prerequisites.md`](../managing-minipc/references/host-prerequisites.md) 참조. 본 스킬 고유 의존:

- agenix secret: `/run/agenix/copyparty-password`, `/run/agenix/pushover-copyparty`
- 도메인: `https://copyparty.greenhead.dev`
- Podman/서비스 의존: `podman-copyparty.service` + `copyparty-config.service` (oneshot, agenix secret 주입)
- 외부 의존: GitHub Releases API + Pushover API (`copyparty-update` 버전 체크 + 알림)

## 레퍼런스

- 설치/설정 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
