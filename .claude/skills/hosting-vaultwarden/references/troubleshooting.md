# Vaultwarden 트러블슈팅

## 1. Bitwarden 클라이언트에서 로그인 실패

**증상**: 올바른 이메일/비밀번호를 입력해도 로그인 안 됨

**원인**: 클라이언트가 기본 Bitwarden 서버(`vault.bitwarden.com`)에 연결 시도

**해결**:
1. 로그인 화면에서 Region → **Self-hosted** 선택
2. Server URL: `https://vaultwarden.greenhead.dev` 입력
3. 저장 후 다시 로그인

## 2. 관리자 패널 접근 불가

**증상**: `/admin` 페이지에서 토큰 입력 후 로그인 실패

**진단**:
```bash
# 환경변수 파일 존재 확인
ls -la /run/vaultwarden-env

# 토큰 값 확인
sudo cat /run/vaultwarden-env

# 환경변수 생성 서비스 상태
systemctl status vaultwarden-env
```

**해결**: 환경변수 파일이 없으면 서비스 재시작
```bash
sudo systemctl restart vaultwarden-env
sudo systemctl restart podman-vaultwarden
```

## 3. 컨테이너 시작 실패

**진단**:
```bash
journalctl -u podman-vaultwarden --no-pager -n 50
sudo podman logs vaultwarden
```

**흔한 원인**:
- 환경변수 파일 미존재 → `ConditionPathExists` 실패 → `vaultwarden-env` 서비스 확인
- 포트 충돌 → `ss -tlnp | grep 8222`
- 이미지 pull 실패 → `sudo podman pull vaultwarden/server:1.35.2`

## 4. 백업 실패

**진단**:
```bash
journalctl -u vaultwarden-backup.service --no-pager
```

**흔한 원인**:
- 소스 디렉토리 비어있음 (컨테이너 미시작 상태) → 의도적 안전장치
- HDD 마운트 안 됨 → `mount | grep /mnt/data`
- SQLite DB 잠김 → 컨테이너 활발히 쓰는 중 (드문 경우, 재시도하면 해결)

## 5. 동기화 안 됨 (클라이언트)

**진단**:
```bash
# 서버 상태 확인
curl -sf http://localhost:8222/alive && echo "Server OK" || echo "Server DOWN"

# Tailscale 연결 확인 (클라이언트에서)
ping 100.79.80.95

# HTTPS 확인
curl -I https://vaultwarden.greenhead.dev
```

**해결**:
- Tailscale 앱이 클라이언트 기기에서 실행 중인지 확인
- 클라이언트 앱에서 수동 동기화 시도 (Bitwarden 설정 → Sync → Sync Vault Now)

## 6. nrs 후 exit code 4

**증상**: `nrs` 적용 시 `switch-to-configuration exited with status 4` 경고 표시

**원인**: 컨테이너 재시작 직후 Podman 헬스체크 transient 서비스가 start-period(30초) 내에 실행되어 실패

**현재 동작**: `nrs.sh`가 exit code 4를 경고로 자동 처리하므로 빌드 결과물 정리 등 후속 작업 정상 진행
```bash
# 경고 메시지 예시:
# ⚠️  switch-to-configuration exited with status 4 (transient unit failures, e.g. health check start period)
#    Services are likely healthy. Verify: sudo podman ps

# 30초 후 확인
sudo podman inspect vaultwarden | jq '.[0].State.Health.Status'
# Expected: "healthy"
```

**수동 restart 직후에도 동일 현상 가능**: `sudo systemctl restart podman-vaultwarden` 후 30초 이내 헬스체크 실패는 정상. start-period 이후 자동 healthy 전환.

## 7. admin token 변경

```bash
# 1. 새 토큰 생성
openssl rand -hex 32

# 2. agenix secret 수정
cd ~/Workspace/nixos-config
nix run github:ryantm/agenix -- -e secrets/vaultwarden-admin-token.age

# 3. 적용
nrs
# 컨테이너가 새 토큰으로 자동 재시작됨
```

## 8. 이미지 업데이트

```bash
# 현재 버전 확인
sudo podman inspect vaultwarden | jq -r '.[0].ImageName'

# vaultwarden.nix에서 버전 태그 변경 후
nrs

# 변경 확인
sudo podman ps | grep vaultwarden
```
