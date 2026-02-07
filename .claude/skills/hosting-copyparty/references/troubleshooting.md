# Copyparty 트러블슈팅

## 1. 컨테이너 시작 실패

**증상**: `podman-copyparty` 서비스가 시작되지 않음

**진단**:
```bash
systemctl status podman-copyparty          # ConditionPathExists 실패 여부 확인
systemctl status copyparty-config          # 설정 생성 서비스 상태
journalctl -u copyparty-config             # 설정 생성 로그
ls -la /var/lib/docker-data/copyparty/config/copyparty.conf  # 설정 파일 존재 확인
```

**해결**:
- `ConditionPathExists` 실패 시: `copyparty-config` 서비스가 먼저 성공해야 함
- 설정 생성 실패 시: agenix 시크릿 복호화 확인 (`ls -la /run/agenix/copyparty-password`)
- `sudo systemctl restart copyparty-config && sudo systemctl restart podman-copyparty`

## 2. 로그인 실패

**증상**: 웹 UI에서 greenhead 계정으로 로그인 불가

**진단**:
```bash
sudo cat /run/agenix/copyparty-password              # 복호화된 비밀번호 확인
sudo cat /var/lib/docker-data/copyparty/config/copyparty.conf  # 설정 파일 내 계정 확인
sudo cat /run/agenix/copyparty-password | xxd         # 바이트 레벨 확인 (이스케이프 문자)
```

**해결**:
- 비밀번호에 이스케이프 문자(`\`)가 포함되면 `agenix -e secrets/copyparty-password.age`로 재입력
- 설정 파일 재생성: `sudo systemctl restart copyparty-config && sudo systemctl restart podman-copyparty`

## 3. 파일 삭제/수정 불가

**증상**: `/immich` 또는 `/backups` 경로에서 파일 삭제/업로드 시 권한 거부

**진단**:
```bash
sudo cat /var/lib/docker-data/copyparty/config/copyparty.conf | grep -A3 'immich\|backups'
```

**해결**:
- 의도된 동작: `/immich`과 `/backups`는 읽기 전용(`r:`) ACL로 설정됨
- Immich 파일은 Immich 앱에서만 관리해야 DB 일관성 유지
- 백업 파일은 자동 백업 시스템이 관리

## 4. IP 바인딩 실패

**증상**: `curl http://100.79.80.95:3923` 연결 거부

**진단**:
```bash
tailscale ip -4                             # Tailscale IP 할당 확인
ss -tlnp | grep 3923                        # 포트 리스닝 확인
podman logs copyparty 2>&1 | tail -20       # 컨테이너 로그
journalctl -u podman-copyparty | grep -i bind  # 바인딩 에러
```

**해결**:
- Tailscale VPN 연결 확인 (클라이언트 측)
- 방화벽 확인: `sudo iptables -L -n | grep 3923`
- 서비스 재시작: `sudo systemctl restart podman-copyparty`

## 5. 비밀번호 변경

**절차**:
```bash
# 1. 시크릿 파일 재암호화
agenix -e secrets/copyparty-password.age
# 에디터에서 새 비밀번호 입력 후 저장

# 2. 빌드 적용
nrs

# 3. 설정 재생성 + 컨테이너 재시작 (nrs가 처리하지만 수동 필요시)
sudo systemctl restart copyparty-config
sudo systemctl restart podman-copyparty
```
