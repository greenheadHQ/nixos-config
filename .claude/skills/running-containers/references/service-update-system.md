# 통합 서비스 업데이트 시스템

## 개요

Immich, Uptime Kuma, Copyparty, Karakeep 4개 컨테이너 서비스가 `service-lib.sh` 공통 라이브러리를 공유하는 업데이트 인프라.

- **버전 체크 (자동)**: 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
- **업데이트 (수동)**: `sudo <서비스>-update` 명령으로 안전한 업데이트

## 아키텍처

```
modules/nixos/lib/
├── service-lib.sh            ← 공통 셸 라이브러리
├── service-lib.nix           ← Nix wrapper (writeText)
├── mk-update-module.nix      ← 업데이트 모듈 생성 헬퍼
└── generic-version-check.sh  ← 공통 버전 체크 스크립트

modules/nixos/programs/
├── immich-update/
│   ├── default.nix           ← NixOS 모듈 (독자 구현, Immich API 사용)
│   └── files/
│       ├── version-check.sh  ← Immich 전용 버전 체크
│       └── update-script.sh  ← 수동 업데이트
├── uptime-kuma-update/
│   ├── default.nix           ← mk-update-module.nix 사용
│   └── files/
│       └── update-script.sh  ← 수동 업데이트 (SQLite 백업 포함)
├── copyparty-update/
│   ├── default.nix           ← mk-update-module.nix 사용
│   └── files/
│       └── update-script.sh  ← 수동 업데이트
└── karakeep-update/
    ├── default.nix           ← mk-update-module.nix 사용
    └── files/
        └── update-script.sh  ← 수동 업데이트
```

### mk-update-module.nix

Copyparty, Uptime Kuma, Karakeep 등 GitHub Releases 기반 서비스의 공통 패턴을 추출한 헬퍼. 서비스명, GitHub 레포, 시크릿 등을 파라미터로 전달하면 systemd service/timer, tmpfiles, agenix 시크릿, update 래퍼를 자동 생성.

Immich는 Immich API로 현재 버전을 확인하는 고유 로직이 있어 독자 구현 유지.

## 공통 라이브러리 (service-lib.sh)

각 서비스에서 `source "$SERVICE_LIB"`로 로드. 환경변수 `SERVICE_LIB`는 systemd environment 또는 래퍼 스크립트에서 주입.

| 함수 | 용도 |
|------|------|
| `send_notification()` | Pushover 알림 (기본 priority `-1` 무음) |
| `fetch_github_release()` | GitHub API → 전역변수 `GITHUB_LATEST_VERSION`, `GITHUB_RESPONSE` 설정 |
| `get_image_digest()` | podman inspect로 컨테이너 이미지 digest 반환 |
| `check_watchdog()` | 3일 초과 실패 시 경고 알림 |
| `check_initial_run()` | 최초 실행 시 버전 기록만 (알림 없음) |
| `record_success()` | last-success 타임스탬프 갱신 |
| `http_health_check()` | HTTP 200 응답 대기 (헬스체크) |

### 주의사항

- **subshell 호출 금지**: `$(fetch_github_release ...)` → 전역변수 손실. 반드시 직접 호출
- **`[ ] && action` 패턴 금지**: `set -e`에서 조건 불일치 시 exit 1. 반드시 `if`문 사용
- **PUSHOVER_TOKEN/USER 사전 로드**: ERR trap보다 먼저 `source "$PUSHOVER_CRED_FILE"` 필요

## 서비스별 차이점

### Immich

- **현재 버전 확인**: Immich API (`/api/server/version`) → `major.minor.patch`
- **알림 형태**: "현재: v2.5.5 → 최신: v2.6.0" (현재/최신 모두 표시)
- **업데이트**: DB 백업(pg_dump) → 이미지 pull 2개 → 재시작 → API 헬스체크
- **Tailscale 대기**: version-check에 `ExecStartPre` tailscale-wait 포함

### Uptime Kuma

- **현재 버전 확인**: 이미지에 버전 레이블 없음 → GitHub latest만 추적
- **알림 형태**: "v2.1.0 출시됨" (현재 버전 미표시)
- **메이저 불일치 감지**: 이미지 태그 `:1`은 1.x만, GitHub latest가 2.x → 추가 안내 포함
- **업데이트**: 이미지 pull → digest 비교 → stop → SQLite 백업(`kuma.db` gzip) → start → HTTP 헬스체크
- **ERR trap 복구**: 실패 시 컨테이너 자동 재시작 (모니터링 서비스 가용성 보장)
- **Tailscale 불필요**: localhost + 인터넷만 사용

### Copyparty

- **현재 버전 확인**: 이미지에 버전 레이블 없음 → GitHub latest만 추적
- **알림 형태**: "v1.20.6 출시됨"
- **업데이트**: 이미지 pull → digest 비교 → 재시작 → HTTP 헬스체크 (백업 없음)
- **ERR trap 복구**: 실패 시 컨테이너 자동 재시작
- **Tailscale 불필요**: localhost + 인터넷만 사용

### Karakeep

- **현재 버전 확인**: 이미지에 버전 레이블 없음 → GitHub latest만 추적
- **알림 형태**: "v0.x.y 출시됨"
- **업데이트**: 이미지 pull → digest 비교 → 재시작 → HTTP 헬스체크 (백업 없음)
- **ERR trap 복구**: 실패 시 컨테이너 자동 재시작
- **Tailscale 불필요**: localhost + 인터넷만 사용

## 타이머 분산

| 서비스 | OnCalendar | RandomizedDelaySec |
|--------|------------|-------------------|
| Immich | `*-*-* 03:00:00` | 5m |
| Uptime Kuma | `*-*-* 03:30:00` | 5m |
| Copyparty | `*-*-* 04:00:00` | 5m |
| Karakeep | `*-*-* 06:00:00` | 5m |

## agenix 시크릿

| 시크릿 | 정의 위치 | 용도 |
|--------|----------|------|
| `pushover-immich` | `immich.nix` | Immich 업데이트/클린업 알림 |
| `pushover-uptime-kuma` | `uptime-kuma-update/default.nix` | Uptime Kuma 업데이트 알림 |
| `pushover-copyparty` | `copyparty-update/default.nix` | Copyparty 업데이트 알림 |
| `pushover-karakeep` | `karakeep-update/default.nix` | Karakeep 업데이트 알림 |

`age.identityPaths`는 `immich.nix`에서 이미 정의. 새 모듈에서 중복 정의 금지.

## 트러블슈팅

### 공통

```bash
# 수동 실행 + 로그 확인
sudo systemctl start <서비스>-version-check.service
journalctl -u <서비스>-version-check --no-pager

# dry-run
sudo <서비스>-update --dry-run

# 타이머 확인
systemctl list-timers | grep version-check

# 시크릿 확인
sudo ls -la /run/agenix/ | grep pushover
```

### "Already notified" 반복 시

초기 실행 후 last-notified-version에 기록된 버전과 동일 → 정상.
새 버전이 출시되면 자동 알림.

```bash
cat /var/lib/<서비스>-update/last-notified-version
```

### 이미지 digest 변경 감지 안 됨

`sudo <서비스>-update`에서 "Image unchanged" 출력 → 레지스트리에 새 이미지가 없는 것.
GitHub에 새 릴리즈가 있더라도 이미지 빌드에 시간 소요.

### 새 서비스 추가 시

1. `modules/nixos/programs/<서비스>-update/` 디렉토리 생성
2. `default.nix`에서 `import ../../lib/mk-update-module.nix { ... }` 사용 (copyparty-update 참고)
3. `files/update-script.sh` 작성 (서비스별 업데이트 로직)
4. `secrets/pushover-<서비스>.age` 시크릿 생성 + `secrets/secrets.nix` 추가
5. `homeserver.nix`에 옵션 + import 추가
6. `configuration.nix`에 enable 추가
