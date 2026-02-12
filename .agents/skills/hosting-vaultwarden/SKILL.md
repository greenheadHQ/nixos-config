---
name: hosting-vaultwarden
description: |
  Vaultwarden/Bitwarden: password manager, admin panel, backup.
  Triggers: "비밀번호 관리자", "볼트워든", "vaultwarden 설정",
  "vaultwarden 백업", "비밀번호 서버", "비밀번호 동기화",
  "master password", "admin token", "admin 패널",
  "vaultwarden 업데이트", "vaultwarden 복원", "backup restore",
  Bitwarden client connection issues, vault sync problems.
---

# Vaultwarden 비밀번호 관리자 관리

Bitwarden 호환 셀프호스팅 비밀번호 관리자입니다.
Podman 컨테이너로 실행되며, Caddy HTTPS 리버스 프록시(`https://vaultwarden.greenhead.dev`)를 통해 Tailscale VPN 내에서 접근합니다.
Mac 브라우저 확장 + iPhone Bitwarden 앱에서 사용합니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `vaultwarden` mkOption 정의 |
| `modules/nixos/programs/docker/vaultwarden.nix` | Podman 컨테이너 + 시크릿 주입 |
| `modules/nixos/programs/docker/vaultwarden-backup.nix` | 매일 SQLite 안전 백업 (SSD -> HDD) |
| `modules/nixos/programs/caddy.nix` | Caddy HTTPS 리버스 프록시 (Vaultwarden 포함) |
| `secrets/vaultwarden-admin-token.age` | agenix 암호화 관리자 토큰 |
| `libraries/constants.nix` | 포트 (`vaultwarden = 8222`), 리소스 제한 |

## 빠른 참조

### 접근 방법

| 방식 | URL |
|------|-----|
| 웹 볼트 | `https://vaultwarden.greenhead.dev` |
| 관리자 패널 | `https://vaultwarden.greenhead.dev/admin` |
| 내부 (localhost) | `http://127.0.0.1:8222` |

관리자 패널 토큰: agenix secret (`vaultwarden-admin-token.age`)

### 서비스 관리

```bash
sudo podman ps | grep vaultwarden              # 컨테이너 상태
sudo podman logs vaultwarden                   # 로그 확인
systemctl status podman-vaultwarden            # systemd 서비스 상태
systemctl status vaultwarden-env               # 환경변수 생성 서비스 상태
journalctl -u podman-vaultwarden -f            # 로그 실시간
sudo ss -tlnp | grep 8222                      # 포트 리스닝 확인
curl -sf http://localhost:8222/alive           # 헬스체크
sudo podman inspect vaultwarden | jq '.[0].State.Health'  # 헬스 상태 상세
```

### 백업

```bash
sudo systemctl start vaultwarden-backup.service  # 수동 백업
systemctl list-timers | grep vaultwarden          # 타이머 확인
sudo ls -la /mnt/data/backups/vaultwarden/        # 백업 파일 확인
journalctl -u vaultwarden-backup.service          # 백업 로그
```

백업 구조:
- **SQLite DB**: `sqlite3 .backup` → gzip 압축 → `gunzip -t` 무결성 검증
- **기타 파일**: rsync (첨부파일, RSA 키, icon cache 등)
- **보존**: 30일 (비밀번호 관리자이므로 다른 서비스 7일보다 길게)
- **스케줄**: 매일 04:30 KST
- **위치**: `/mnt/data/backups/vaultwarden/YYYY-MM-DD/`

### 클라이언트 설정

**Mac (Bitwarden 브라우저 확장)**:
1. 확장 프로그램 로그인 화면에서 Region → **Self-hosted** 선택
2. Server URL: `https://vaultwarden.greenhead.dev`
3. 이메일 + Master Password로 로그인

**iPhone (Bitwarden 앱)**:
1. 로그인 화면에서 Region → **Self-hosted** 선택
2. Server URL: `https://vaultwarden.greenhead.dev`
3. 이메일 + Master Password로 로그인
4. Face ID 잠금 해제 활성화 권장

**오프라인 사용**: 클라이언트가 vault를 로컬 캐시하므로 Tailscale 없이도 비밀번호 조회 가능. 동기화만 VPN 필요.

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.vaultwarden.enable = true;     # 활성화
homeserver.vaultwarden.port = 8222;       # 포트 (기본값은 constants.nix)
```

## 보안 구성

| 항목 | 설정 | 설명 |
|------|------|------|
| 회원가입 | `SIGNUPS_ALLOWED=false` | 공개 회원가입 차단 |
| 초대 | `INVITATIONS_ALLOWED=false` | 사용자 간 초대 차단 |
| 비밀번호 힌트 | `SHOW_PASSWORD_HINT=false` | 힌트 노출 방지 |
| 로그인 제한 | `LOGIN_RATELIMIT=5/60` | 60초당 5회 |
| 관리자 제한 | `ADMIN_RATELIMIT=3/60` | 60초당 3회 |
| 포트 바인딩 | `127.0.0.1:8222` | localhost 전용 |
| 데이터 권한 | `0700` | root만 접근 |
| 시크릿 | tmpfs (`/run/vaultwarden/env`) | 재부팅 시 자동 소멸 |

## 스토리지 구조

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/var/lib/docker-data/vaultwarden/data` | SSD | SQLite DB + 첨부파일 + RSA 키 (0700) |
| `/run/vaultwarden/env` | tmpfs | ADMIN_TOKEN 환경변수 파일 (0400) |
| `/mnt/data/backups/vaultwarden` | HDD | 일별 백업 (30일 보존, 0700) |

## Known Issues

**ADMIN_TOKEN 평문 경고**
- 관리자 패널에 "plain text ADMIN_TOKEN is insecure" 경고 표시
- Argon2id 해싱으로 전환 가능하나, 초기 복잡도를 고려하여 v1에서는 평문 사용
- Tailscale 전용 + root 권한 필수 환경에서 실질적 위험 낮음
- 향후 개선: 컨테이너 내부에서 `vaultwarden hash` → agenix secret 교체

**환경변수 파일 주입 방식 (caddy-env 패턴)**
- Vaultwarden은 `_FILE` 접미사 환경변수 미지원
- `vaultwarden-env` oneshot 서비스가 agenix secret → tmpfs 환경변수 파일 생성
- `environmentFiles`로 컨테이너에 주입, `ConditionPathExists`로 안전장치
- 패턴 동일: `caddy-env` (Cloudflare token), `copyparty-config` (비밀번호)

**SIGNUPS_ALLOWED=false에서 계정 생성**
- 로그인 페이지에 "Create Account" 버튼 미표시 (정상)
- 관리자 패널(`/admin`) → Users → Invite로 이메일 초대
- 초대 후 `/#/register`에 직접 접속하여 계정 생성 (초대된 이메일만 허용)

**WebSocket 실시간 동기화**
- Vaultwarden v1.29+에서 WebSocket이 동일 HTTP 포트로 통합
- Caddy `reverse_proxy`가 WebSocket 업그레이드를 자동 처리
- 별도 설정 불필요 (별도 WebSocket 포트/경로 프록시 불필요)

**헬스체크 시작 시 일시 실패**
- `nrs` 적용 직후 헬스체크 타이머가 start-period(30초) 내에 실행되면 exit code 4 발생
- 정상 동작: 30초 후 `healthy` 상태로 전환
- 확인: `sudo podman inspect vaultwarden | jq '.[0].State.Health.Status'`

**이미지 버전 고정 (자동 업데이트 미구현)**
- `vaultwarden/server:1.35.2` (`:latest` 미사용)
- 재부팅 시 예기치 않은 버전 변경 방지
- immich/uptime-kuma/copyparty와 달리 자동 버전 체크 시스템 없음
- 업데이트 시 `vaultwarden.nix`에서 버전 태그 수동 변경 후 `nrs`

**Master Password 복구 불가**
- Bitwarden은 클라이언트 측 암호화 (서버에 키 저장 안 함)
- Master Password를 잊으면 서버 관리자도 vault 복구 불가능
- 비상 대책: Master Password를 안전한 물리적 장소에 별도 보관

## 자주 발생하는 문제

1. **Bitwarden 클라이언트 로그인 실패**: Region → Self-hosted → Server URL 설정 확인
2. **관리자 패널 접근 불가**: `cat /run/vaultwarden/env`로 토큰 확인, `systemctl status vaultwarden-env`
3. **컨테이너 시작 실패**: `journalctl -u podman-vaultwarden`에서 원인 확인
4. **백업 실패**: 소스 디렉토리 비어있으면 안전하게 중단 (의도적 동작)
5. **동기화 안 됨**: Tailscale VPN 연결 확인, `curl -sf http://localhost:8222/alive`
6. **admin token 변경**: `agenix -e secrets/vaultwarden-admin-token.age` → `nrs` → 컨테이너 자동 재시작

## 레퍼런스

- 설정/운영 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
