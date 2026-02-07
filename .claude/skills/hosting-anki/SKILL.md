---
name: hosting-anki
description: |
  This skill should be used when the user asks about Anki sync server,
  "anki 동기화", "anki-sync-server", "anki 서버", "anki 백업",
  or encounters sync server connection issues, backup failures,
  client configuration problems with Anki Desktop or AnkiMobile.
---

# Anki Sync Server 관리

NixOS 네이티브 `services.anki-sync-server` 모듈로 Anki 동기화 서버를 셀프호스팅합니다.
Tailscale VPN 내에서만 접근 가능하며, agenix로 비밀번호를 관리합니다.

## 모듈 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `ankiSync` mkOption 정의 |
| `modules/nixos/programs/anki-sync-server/default.nix` | 서비스 설정 (네이티브 모듈 래핑) |
| `modules/nixos/programs/anki-sync-server/backup.nix` | 매일 백업 타이머 (SSD -> HDD) |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `secrets/anki-sync-password.age` | agenix 암호화 비밀번호 |
| `libraries/constants.nix` | 포트 (`ankiSync = 27701`) |

## 빠른 참조

### 서비스 관리

```bash
systemctl status anki-sync-server.service    # 상태 확인
journalctl -u anki-sync-server.service -f    # 로그 실시간
ss -tlnp | grep 27701                        # 포트 리스닝 확인
sudo systemctl restart anki-sync-server      # 재시작
```

### 백업

```bash
sudo systemctl start anki-sync-backup.service   # 수동 백업
systemctl list-timers | grep anki                # 타이머 확인
ls -la /mnt/data/backups/anki/                   # 백업 파일 확인
journalctl -u anki-sync-backup.service           # 백업 로그
```

### 클라이언트 설정

**macOS Desktop (Anki 2.1.66+)**:
1. Tools > Preferences > Syncing
2. Self-hosted sync server: `http://100.79.80.95:27701/`
3. Anki 재시작 후 Sync

**AnkiMobile (iOS)**:
1. iOS 설정 앱 > Anki
2. SYNCING > Custom sync server: `http://100.79.80.95:27701/`
3. Media sync URL: 비워둠
4. Anki 앱에서 Sync

사용자: `greenhead` / 비밀번호: agenix secret

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.ankiSync.enable = true;   # 활성화
homeserver.ankiSync.port = 27701;    # 포트 (기본값은 constants.nix)
```

## Known Issues

**로그인 UI에 "AnkiWeb" 표시**
- 커스텀 sync 서버를 설정해도 로그인 다이얼로그에 "AnkiWeb 아이디"라고 표시됨
- 정상 동작: 실제로는 커스텀 서버로 연결되므로 셀프호스팅 자격증명 입력

**age 암호화 시 특수문자 이스케이프**
- `nix-shell --run` 파이프로 비밀번호 전달 시 `!` 등 특수문자에 `\` 추가됨
- 해결: 임시 파일 경유로 암호화 (`printf 'pw' > /tmp/pw && age ... /tmp/pw`)
- 진단: `sudo cat /run/agenix/anki-sync-password | xxd`로 바이트 확인

**DynamicUser + Tailscale 소켓 접근**
- upstream 모듈이 `DynamicUser = true` 사용
- `ExecStartPre`에서 tailscale-wait 스크립트 실행 시 소켓 접근 불가
- 해결: `"+"` prefix로 root 권한 실행

**Tailscale IP 타이밍**
- 부팅 시 Tailscale IP 할당 전에 서비스 시작하면 바인딩 실패
- 해결: `tailscale-wait.nix`로 60초 대기 (컨테이너 서비스와 동일 패턴)

**openFirewall 비활성**
- 네이티브 모듈의 `openFirewall`은 모든 인터페이스에 포트 개방
- `trustedInterfaces = [ "tailscale0" ]`가 Tailscale 전체 트래픽 허용하므로 별도 방화벽 룰 불필요
- 보안은 Tailscale IP 바인딩(`address = minipcTailscaleIP`)에 의존

**데이터 디렉토리**
- 네이티브 모듈이 `StateDirectory`로 `/var/lib/anki-sync-server/` 자동 관리
- `DynamicUser = true`이므로 디렉토리 소유권은 systemd가 처리

## 자주 발생하는 문제

1. **Sync 연결 실패**: Tailscale VPN 연결 확인, `ss -tlnp | grep 27701`
2. **인증 실패**: agenix secret 복호화 확인 (`ls -la /run/agenix/anki-sync-password`)
3. **백업 실패**: 소스 디렉토리 비어있으면 안전하게 중단 (의도적 동작)
4. **서비스 시작 실패**: `journalctl -u anki-sync-server.service`로 원인 확인

## 레퍼런스

- 설치/설정 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
