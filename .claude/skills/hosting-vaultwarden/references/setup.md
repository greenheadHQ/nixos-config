# Vaultwarden 설정 상세

## 컨테이너 구성

```
이미지: vaultwarden/server:1.35.2
포트: 127.0.0.1:8222:80 (localhost → Caddy)
볼륨: /var/lib/docker-data/vaultwarden/data:/data
리소스: memory=256m, cpus=0.5
헬스체크: curl -sf http://localhost:80/alive (60초 간격, 30초 start period)
```

## 환경변수

| 변수 | 값 | 설명 |
|------|-----|------|
| `DOMAIN` | `https://vaultwarden.greenhead.dev` | 클라이언트가 참조하는 서버 URL |
| `SIGNUPS_ALLOWED` | `false` | 공개 회원가입 차단 |
| `INVITATIONS_ALLOWED` | `false` | 사용자 간 초대 차단 |
| `SHOW_PASSWORD_HINT` | `false` | 비밀번호 힌트 비활성화 |
| `LOGIN_RATELIMIT` | `5/60` | 로그인 시도 제한 (60초당 5회) |
| `ADMIN_RATELIMIT` | `3/60` | 관리자 로그인 제한 (60초당 3회) |
| `ROCKET_PORT` | `80` | 컨테이너 내부 포트 |
| `TZ` | `Asia/Seoul` | 시스템 타임존 참조 |
| `ADMIN_TOKEN` | (환경변수 파일) | agenix → tmpfs 주입 |

## 시크릿 주입 흐름

```
agenix 복호화 (/run/agenix/vaultwarden-admin-token)
  ↓
vaultwarden-env oneshot 서비스 (시작 전)
  ↓
/run/vaultwarden-env (tmpfs, 0400)
  ↓
podman --env-file (environmentFiles)
  ↓
ADMIN_TOKEN 환경변수로 컨테이너에 전달
```

## 새 사용자 추가 (관리자 전용)

1. `https://vaultwarden.greenhead.dev/admin` → 토큰 입력
2. Users 탭 → 이메일 입력 → Invite
3. `https://vaultwarden.greenhead.dev/#/register` → 초대된 이메일로 계정 생성

SMTP 미설정이므로 초대 메일은 발송되지 않음. 관리자 패널에서 초대만 하면 해당 이메일로 가입 허용.

## 백업 복원 절차

긴급 복원이 필요한 경우:

```bash
# 1. 컨테이너 중지
sudo systemctl stop podman-vaultwarden

# 2. 현재 데이터 백업 (안전장치)
sudo cp -a /var/lib/docker-data/vaultwarden/data /var/lib/docker-data/vaultwarden/data.bak

# 3. 백업에서 복원
BACKUP_DATE="2026-02-11"  # 복원할 날짜
sudo gunzip -k /mnt/data/backups/vaultwarden/$BACKUP_DATE/db.sqlite3.gz
sudo cp /mnt/data/backups/vaultwarden/$BACKUP_DATE/db.sqlite3 /var/lib/docker-data/vaultwarden/data/
sudo rsync -a --exclude='db.sqlite3*' /mnt/data/backups/vaultwarden/$BACKUP_DATE/ /var/lib/docker-data/vaultwarden/data/

# 4. 컨테이너 재시작
sudo systemctl start podman-vaultwarden

# 5. 확인
curl -sf http://localhost:8222/alive && echo "OK"
```

## 버전 업데이트

```bash
# 1. 릴리스 노트 확인
# https://github.com/dani-garcia/vaultwarden/releases

# 2. vaultwarden.nix에서 이미지 태그 변경
# image = "vaultwarden/server:1.35.2" → "vaultwarden/server:X.Y.Z"

# 3. 빌드 & 적용
nrs

# 4. 확인
sudo podman ps | grep vaultwarden
curl -sf http://localhost:8222/alive
```

## Cloudflare DNS 설정

| 항목 | 값 |
|------|-----|
| Type | A |
| Name | `vaultwarden` |
| Content | `100.79.80.95` (Tailscale IP) |
| Proxy | OFF (DNS only, 회색 구름) |

DNS-01 ACME 인증서는 Caddy가 Cloudflare API로 자동 관리.
