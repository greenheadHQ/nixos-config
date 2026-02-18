# Linkwarden 트러블슈팅

## 서비스 시작 실패

```bash
# 로그 확인
journalctl -u linkwarden -n 50 --no-pager

# 시크릿 파일 존재 확인
ls -la /run/agenix/linkwarden-nextauth-secret
ls -la /run/agenix/meilisearch-master-key

# PostgreSQL 상태 확인
systemctl status postgresql
sudo -u postgres psql -l | grep linkwarden
```

**NEXTAUTH_SECRET 누락**: agenix secret 파일이 없으면 서비스 시작 실패. `agenix -e secrets/linkwarden-nextauth-secret.age`로 생성.

## Meilisearch 연결 실패

```bash
# Meilisearch 상태
systemctl status meilisearch
curl -sf http://localhost:7700/health

# 마스터 키 확인
sudo cat /run/agenix/meilisearch-master-key
```

## 아카이브 저장 실패

```bash
# HDD 마운트 확인
mount | grep /mnt/data
df -h /mnt/data

# 아카이브 디렉토리 권한 확인
ls -la /mnt/data/linkwarden/
ls -la /mnt/data/linkwarden/archives/

# linkwarden 사용자 확인
id linkwarden
```

## 백업 실패

```bash
# 백업 로그
journalctl -u linkwarden-db-backup -n 50

# PostgreSQL 접근 확인
sudo -u postgres pg_dump -Fc linkwarden > /dev/null && echo "OK"

# 디스크 공간
df -h /mnt/data/backups/linkwarden/
```

## HTTPS 접근 불가

```bash
# Caddy 상태
systemctl status caddy
journalctl -u caddy -n 20

# Tailscale 연결
tailscale status

# DNS 확인
dig archive.greenhead.dev
```

## 성능 이슈

```bash
# 메모리 사용량
systemctl status linkwarden | grep Memory
systemctl status meilisearch | grep Memory
systemctl status postgresql | grep Memory

# Meilisearch 인덱스 크기
du -sh /var/lib/meilisearch/
```

Meilisearch 메모리 제한이 필요한 경우:
```nix
systemd.services.meilisearch.serviceConfig.MemoryMax = "512M";
```
