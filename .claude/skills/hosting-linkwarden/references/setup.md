# Linkwarden 설정 레퍼런스

## 초기 설정

### 1. 시크릿 생성 (Mac에서)

```bash
cd ~/IdeaProjects/nixos-config

# NEXTAUTH_SECRET (세션 암호화, 랜덤 32바이트)
openssl rand -base64 32 | nix run github:ryantm/agenix -- -e secrets/linkwarden-nextauth-secret.age

# Meilisearch master key (검색 엔진 인증)
openssl rand -hex 16 | nix run github:ryantm/agenix -- -e secrets/meilisearch-master-key.age

# Pushover credentials (버전 체크 + 백업 알림)
# 형식: PUSHOVER_TOKEN=xxx\nPUSHOVER_USER=yyy
nix run github:ryantm/agenix -- -e secrets/pushover-linkwarden.age
```

### 2. Cloudflare DNS 레코드

Cloudflare 대시보드에서 A 레코드 추가:
- Type: A
- Name: archive
- Content: 100.79.80.95 (Tailscale IP)
- Proxy: OFF (DNS only)

### 3. 배포

```bash
ssh minipc
cd ~/IdeaProjects/nixos-config && git pull && nrs
```

### 4. 첫 사용자 등록

1. `https://archive.greenhead.dev` 접속
2. 이메일 + 비밀번호로 첫 번째 사용자 생성
3. 이후 추가 등록 자동 차단 (`enableRegistration = false`)

### 5. 클라이언트 설정

**Chrome 확장**: Chrome Web Store → "Linkwarden" 검색 → 설치 → Instance URL 설정

**iOS 앱**: App Store → "Linkwarden" 검색 → 설치 → Server URL 설정

## 아키텍처

```
Client (Chrome 확장 / iOS 앱 / 웹 UI)
  │
  ▼ (Tailscale VPN)
Caddy (archive.greenhead.dev:443, HTTPS)
  │
  ▼ (reverse_proxy localhost:3000)
Linkwarden (NixOS 네이티브 서비스)
  ├── PostgreSQL (services.postgresql, SSD)
  ├── Meilisearch (services.meilisearch, SSD, localhost:7700)
  └── Archive storage (HDD: /mnt/data/linkwarden/archives)
```

## 환경변수

| 변수 | 값 | 소스 |
|------|-----|------|
| NEXTAUTH_SECRET | (랜덤) | agenix secretFiles |
| NEXTAUTH_URL | `https://archive.greenhead.dev/api/v1/auth` | environment |
| MEILI_HOST | `http://127.0.0.1:7700` | environment |
| MEILI_MASTER_KEY | (랜덤) | agenix secretFiles |

## 백업 복원

```bash
# 1. 백업 파일 확인
ls -la /mnt/data/backups/linkwarden/

# 2. Linkwarden 서비스 중지
sudo systemctl stop linkwarden

# 3. 기존 DB 삭제 + 복원
sudo -u postgres dropdb linkwarden
sudo -u postgres createdb linkwarden
sudo -u postgres pg_restore -d linkwarden /mnt/data/backups/linkwarden/linkwarden-db-YYYY-MM-DD_HHMMSS.dump

# 4. 서비스 재시작
sudo systemctl start linkwarden
```
