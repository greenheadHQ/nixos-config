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

## "AnkiWeb 아이디나 비밀번호가 틀렸습니다" (로그인 UI 혼동)

### 증상
커스텀 sync 서버를 설정했는데 로그인 다이얼로그에 "AnkiWeb 아이디"라고 표시됨.
셀프호스팅 서버 로그인인지 AnkiWeb 로그인인지 혼동.

### 원인
Anki는 커스텀 sync 서버를 설정해도 로그인 UI 텍스트가 "AnkiWeb"으로 고정되어 있음.
실제로는 설정한 커스텀 서버로 연결되므로, 셀프호스팅 서버 자격증명을 입력하면 됨.

### 해결
- 아이디: `greenhead` (셀프호스팅 서버에 등록한 사용자명)
- 비밀번호: agenix에 저장한 비밀번호
- "AnkiWeb" 표시는 무시 — 커스텀 서버로 정상 연결됨

## 인증 실패 (비밀번호 이스케이프 문제)

### 증상
올바른 비밀번호를 입력해도 "AnkiWeb 아이디나 비밀번호가 틀렸습니다" 발생.
서버 로그에 `invalid user/pass in get_host_key` 403 에러.

### 진단
```bash
# 복호화된 비밀번호의 실제 바이트 확인
sudo cat /run/agenix/anki-sync-password | xxd

# 예: \! (5c 21)이 보이면 이스케이프 문제
# 00000000: 7061 7373 5c21          pass\!    ← 잘못됨
# 00000000: 7061 7373 21            pass!     ← 정상
```

### 원인
`age` 암호화 시 stdin 파이프로 비밀번호를 전달하면 `nix-shell --run` 내부 셸이
특수문자(`!`, `$`, `` ` `` 등)를 이스케이프하여 `\!`처럼 백슬래시가 추가됨.

### 해결
파이프 대신 **임시 파일 경유**로 암호화:

```bash
printf '비밀번호' > /tmp/pw
nix-shell -p age --run 'age -r "ssh-ed25519 ..." -o secrets/anki-sync-password.age /tmp/pw'
rm /tmp/pw
```

암호화 후 MiniPC에서 `nrs` 재배포 + 서비스 재시작:

```bash
sudo systemctl restart anki-sync-server.service
```

## 인증 실패 (일반)

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
- 비밀번호 변경 시 임시 파일 경유 패턴 사용 (위 "비밀번호 이스케이프 문제" 참조)

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
