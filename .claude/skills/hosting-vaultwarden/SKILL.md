---
name: hosting-vaultwarden
description: |
  Manage Vaultwarden password manager: backup, admin panel, troubleshooting, client sync.
  Trigger: 'vaultwarden', 'Bitwarden', '비밀번호 관리자', '비번 저장소', 'vault 서비스',
  'vaultwarden 백업', 'vaultwarden-update', 'vaultwarden.greenhead.dev', '관리자 패널 토큰',
  'admin token', 'vault 로그'.
  NOT for agenix 시크릿 일반 (use managing-secrets). NOT for 컨테이너/Podman 일반 관리
  (use running-containers).
---

# Vaultwarden 비밀번호 관리자 관리

Bitwarden 호환 셀프호스팅 비밀번호 관리자입니다.
Podman 컨테이너로 실행되며, Caddy HTTPS 리버스 프록시(`https://vaultwarden.greenhead.dev`)를 통해 Tailscale VPN 내에서 접근합니다.
Mac 브라우저 확장 + iPhone Bitwarden 앱에서 사용합니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `vaultwarden` + `vaultwardenUpdate` mkOption 정의 |
| `modules/nixos/programs/docker/vaultwarden.nix` | Podman 컨테이너 + 시크릿 주입 |
| `modules/nixos/programs/docker/vaultwarden-backup.nix` | 매일 SQLite 안전 백업 (SSD -> HDD) |
| `modules/nixos/programs/vaultwarden-update/` | 버전 체크 + 수동 업데이트 자동화 |
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
homeserver.vaultwarden.enable = true;          # 활성화
homeserver.vaultwarden.port = 8222;            # 포트 (기본값은 constants.nix)
homeserver.vaultwardenUpdate.enable = true;    # 버전 체크 + 업데이트 알림 (06:30)
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
| 시크릿 | tmpfs (`/run/vaultwarden-env`) | 재부팅 시 자동 소멸 |

## 스토리지 구조

| 경로 | 디스크 | 용도 |
|------|--------|------|
| `/var/lib/docker-data/vaultwarden/data` | SSD | SQLite DB + 첨부파일 + RSA 키 (0700) |
| `/run/vaultwarden-env` | tmpfs | ADMIN_TOKEN 환경변수 파일 (0400) |
| `/mnt/data/backups/vaultwarden` | HDD | 일별 백업 (30일 보존, 0700) |

## Known Issues

- ADMIN_TOKEN 평문 경고 (Argon2id 전환 미적용)
- 환경변수 파일 주입 방식 (caddy-env 패턴)
- SIGNUPS_ALLOWED=false에서 계정 생성 절차
- 헬스체크 start-period 내 exit code 4
- 이미지 버전 고정 + 수동 업데이트 (`sudo vaultwarden-update`)
- Master Password 복구 불가

상세: [references/known-issues.md](references/known-issues.md)

## 자주 발생하는 문제

1. **Bitwarden 클라이언트 로그인 실패**: Region → Self-hosted → Server URL 설정 확인
2. **관리자 패널 접근 불가**: `cat /run/vaultwarden-env`로 토큰 확인, `systemctl status vaultwarden-env`
3. **컨테이너 시작 실패**: `journalctl -u podman-vaultwarden`에서 원인 확인
4. **백업 실패**: 소스 디렉토리 비어있으면 안전하게 중단 (의도적 동작)
5. **동기화 안 됨**: Tailscale VPN 연결 확인, `curl -sf http://localhost:8222/alive`
6. **admin token 변경**: `(cd secrets && agenix -e vaultwarden-admin-token.age)` → `nrs` → 컨테이너 자동 재시작

## 런타임 환경 전제

공통 NixOS MiniPC 호스트 전제는 [`../managing-minipc/references/host-prerequisites.md`](../managing-minipc/references/host-prerequisites.md) 참조. 본 스킬 고유 의존:

- agenix secret: `/run/agenix/vaultwarden-admin-token`, `/run/agenix/pushover-vaultwarden`
- 도메인: `https://vaultwarden.greenhead.dev`
- Podman/서비스 의존: `vaultwarden-env.service` (envScript로 `/run/vaultwarden-env` env 파일 생성, `podman-vaultwarden.service` 의 `EnvironmentFile`) + `podman-vaultwarden.service`
- 외부 의존: Bitwarden 클라이언트 (Mac 브라우저 확장 / iPhone 앱, 자동화 대상 외 GUI 전제), GitHub Releases API + Pushover API (`vaultwarden-update` 버전 체크 + 알림)

## 레퍼런스

- 설정/운영 상세: [references/setup.md](references/setup.md)
- Known Issues 상세: [references/known-issues.md](references/known-issues.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
