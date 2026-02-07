# Anki Sync Server 트러블슈팅

## Sync 연결 실패

### 증상
Anki 클라이언트에서 "Network error" 또는 "Connection refused"

### 진단
```bash
# 1. 서비스 상태 확인
systemctl status anki-sync-server.service

# 2. Tailscale IP 리스닝 확인
ss -tlnp | grep 27701

# 3. 클라이언트에서 연결 테스트 (macOS)
curl -v http://100.79.80.95:27701/

# 4. 방화벽 확인
sudo iptables -L -n | grep 27701
```

### 해결
- Tailscale 연결 확인: `tailscale status`
- 서비스 재시작: `sudo systemctl restart anki-sync-server`
- IP 바인딩 실패 시: `journalctl -u anki-sync-server.service`에서 에러 확인

## 인증 실패

### 증상
"Authentication failed" 또는 "Invalid credentials"

### 진단
```bash
# agenix 복호화 확인
ls -la /run/agenix/anki-sync-password
sudo cat /run/agenix/anki-sync-password
```

### 해결
- 비밀번호 파일이 없으면: `nrs` 재실행
- 비밀번호 변경: `nix run github:ryantm/agenix -- -e secrets/anki-sync-password.age`

## 서비스 시작 실패

### 증상
`systemctl status`에서 `failed` 또는 `activating`

### 진단
```bash
journalctl -u anki-sync-server.service --since today --no-pager
```

### 일반적인 원인
1. **Tailscale IP 미할당**: tailscale-wait가 60초 후 timeout → Tailscale 상태 확인
2. **포트 충돌**: `ss -tlnp | grep 27701`로 다른 프로세스 확인
3. **시크릿 복호화 실패**: SSH 키 경로 확인 (`/home/greenhead/.ssh/id_ed25519`)

## 백업 실패

### 증상
`journalctl -u anki-sync-backup.service`에서 에러

### 진단
```bash
# 소스 디렉토리 확인
ls -la /var/lib/anki-sync-server/

# 백업 디렉토리 확인
ls -la /mnt/data/backups/anki/

# HDD 마운트 확인
df -h /mnt/data
```

### 해결
- 소스 디렉토리 비어있음: 아직 sync한 적 없으면 정상 (빈 디렉토리 백업 방지)
- HDD 미마운트: `sudo mount /mnt/data`
- 디스크 공간 부족: `df -h` 확인

## Anki 재시작 후 URL 초기화

### 증상
Anki Desktop에서 커스텀 sync 서버 URL이 비워짐

### 해결
- Anki 2.1.66+ 확인 필요 (이전 버전은 커스텀 sync 미지원)
- Preferences에서 URL 재입력 후 반드시 Anki 재시작

## AnkiMobile URL 설정 위치

### 증상
AnkiMobile 앱 내에서 sync 서버 설정을 찾을 수 없음

### 해결
- AnkiMobile은 **iOS 설정 앱** > Anki에서 설정 (앱 내부가 아님)
- SYNCING 섹션 > Custom sync server

## 양방향 Sync 충돌

### 증상
"Please choose which side to keep" 프롬프트

### 해결
1. 최신 데이터가 있는 기기에서 **"Upload"** 선택
2. 다른 기기에서 **"Download"** 선택
3. 이후 정상적으로 양방향 sync 동작

## 로그 확인

```bash
# 실시간 로그
journalctl -u anki-sync-server.service -f

# 오늘 로그에서 에러만
journalctl -u anki-sync-server.service --since today | grep -i error

# 백업 로그
journalctl -u anki-sync-backup.service --since today
```
