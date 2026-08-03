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

재생성 시점은 `copyparty-config` 유닛이 다시 실행될 때입니다. 이 유닛은 `RemainAfterExit = true`라
컨테이너만 재시작해서는 재실행되지 않으므로, 손으로 편집한 내용은 즉시 되돌아가지 않고 Nix 소스와
드리프트한 채 남습니다. 되돌리려면 재생성과 재시작을 함께 해야 합니다 (파일만 되살리면 실행 중인
프로세스는 편집본을 계속 씁니다):

```bash
sudo systemctl restart copyparty-config && sudo systemctl restart podman-copyparty
```

설정 변경은 `modules/nixos/programs/docker/copyparty.nix`의 `configScript`에서 하고 `nrs`로 반영합니다.
`nrs` 한 번으로 재생성과 재시작이 모두 일어나지만, 메커니즘은 서로 다른 두 가지입니다.

| 무엇이 | 왜 |
|--------|-----|
| conf 파일 재생성 | `configScript`가 바뀌면 `copyparty-config`의 `ExecStart` store path가 바뀌어 유닛이 재실행됨 |
| 컨테이너 재시작 | `podman-copyparty`가 그 store path를 `restartTriggers`로 물고 있어 유닛이 변경으로 감지됨 |

이 구분이 중요한 이유는 `restartTriggers`가 다른 유닛을 재실행시킬 수 없기 때문입니다 — 재생성은 트리거가
아니라 config 유닛 자체의 변경으로 일어납니다. 트리거가 빠지면 파일만 새로 써지고 실행 중인 프로세스는 옛
설정을 유지합니다 (copyparty는 시작 시점에만 conf를 읽습니다).

conf의 입력은 `configScript`와 agenix 비밀번호 두 개이므로 양쪽 유닛 모두 `.age` 파일도 트리거로 물고
있습니다. 이게 없으면 비밀번호를 교체해도 `configScript`의 store path가 그대로라 구 비밀번호가 계속
유효합니다.

### 검색 인덱싱

`[global]`의 `e2dsa`가 파일 검색(웹 UI 상단 🔎 버튼)을 활성화합니다. 이 옵션이 없으면 버튼 자체가 표시되지 않습니다.
인덱스 DB는 `hist:` 경로(SSD)에 저장됩니다.

| 옵션 | 값 | 의미 |
|------|-----|------|
| `e2dsa` | (플래그) | 모든 볼륨을 시작 시 스캔하여 up2k DB에 색인 |
| `no-hash` | `.` | 정규식이며 `.`은 모든 경로에 매칭 — 스캔 시 파일 해시 계산 생략 |
| `re-maxage` | `86400` | 하루 1회 재스캔 (Copyparty 밖에서 추가된 파일 반영) |

`no-hash`로 해시를 생략해도 검색(파일명·경로·크기·날짜)은 정상 동작합니다. 포기하는 것은 "이미 디스크에
있던 파일"과의 해시 매칭이라, 서버에 이미 존재하는 파일을 다시 올릴 때 서버 내 복사(clone)로 처리되지 못하고
네트워크로 다시 전송됩니다. 중단된 업로드 이어받기는 up2k 스냅샷(`--snap-wri`) 기반이라 영향받지 않고,
심볼릭링크 중복 제거(`--dedup`)는 이 설정에서 선언한 적이 없어 원래부터 비활성입니다.
HDD 전체를 읽어야 하는 초기 해시 스캔을 피해 다른 서비스와의 디스크 경합을 줄이려는 선택입니다.

기존 파일과의 해시 매칭이 필요해지면 `no-hash` 줄을 제거하고 `nrs`로 재스캔합니다. `nohash`는 copyparty의
`VF_AFFECTS_INDEXING` volflag라 값이 바뀌면 dhash 캐시가 폐기되고 전체를 다시 읽으므로, 재스캔이 조용히
생략되지는 않습니다 (그만큼 장시간 소요).

`e2dsa`는 컨테이너 시작 시점에만 스캔하므로, 백업 스크립트나 Immich처럼 Copyparty 밖에서 파일을 추가하는
경로가 있으면 `re-maxage` 없이는 인덱스가 낡습니다.

스캔이 도는 동안(기동 직후 첫 스캔, 일일 재스캔) 이름 변경·이동 요청은 스캔이 끝날 때까지 응답하지
않습니다. 인덱서가 그 구간 내내 mutex를 잡는데, 인덱서를 중단시킬 수 있는 액션 목록(`--fika`)의 기본값
`ucd`에 이동(`m`)이 빠져 있기 때문입니다 (업로드·복사·삭제는 중단시킬 수 있어 영향 없음).
2회차 이후 스캔은 dhash 가속으로 짧아집니다. 이 창을 줄이려면 `fika: ucmd`를 검토할 수 있지만,
업스트림이 `m`을 `untested/scary`로 표기하고 있어 기본값을 그대로 둡니다.

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
- 설정 변경 반영 절차는 "설정 파일 구조" 절 참조 (`nrs` 한 번으로 처리되며, 수동 경로도 그곳에 있음)

localhost 바인딩 (Caddy 연동)
- 포트가 `127.0.0.1:3923`에 바인딩 (Caddy가 유일한 외부 진입점)
- Tailscale IP 바인딩/tailscale-wait.nix 불필요 (localhost는 항상 사용 가능)

썸네일 캐시
- `th-maxage: 7776000` (90일) 설정
- 캐시 위치: SSD (`/var/lib/docker-data/copyparty/hists`)
- `th-maxsize` 옵션은 존재하지 않음 (사용 금지)
- `e2dsa`가 함의하는 `-e2d`는 폴더 커버 썸네일 선택 규칙을 완화한다 — 커버 파일명(`folder.jpg` 등)이
  없어도 사진이 든 폴더에 커버가 자동 선택되므로, 브라우징 범위만큼 캐시와 HDD 읽기가 늘 수 있다
  (이 자동 선택만 끄는 옵션은 없다). `th-maxage` 축소는 SSD 캐시 용량만 줄이고 HDD 읽기는 오히려
  늘리므로, 두 비용 중 무엇이 문제인지 확인한 뒤 조정한다

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
3. CORS 403 (리버스 프록시): `rproxy: 1` + `xff-src: 10.88.0.0/16` (constants.network.podmanSubnet) 설정 확인 후 재적용 (절차는 "설정 파일 구조" 절)
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
