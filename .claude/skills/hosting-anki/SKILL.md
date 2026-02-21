---
name: hosting-anki
description: |
  Anki sync server + AnkiConnect API: self-hosted sync, headless API, backup, client config.
  Triggers: "anki 동기화", "anki-sync-server", "anki 서버", "anki 백업",
  "AnkiConnect", "anki-connect", "headless anki", "카드 API", "덱 조회",
  "sync connection issues", "backup failures", "AnkiMobile configuration",
  "AnkiMobile 설정", "self-hosted anki sync", "anki CORS", "anki API 테스트".
---

# Anki 서비스 관리

MiniPC에서 두 가지 Anki 서비스를 셀프호스팅합니다:

| 서비스 | 프로토콜 | 용도 | 포트 |
|--------|----------|------|------|
| Anki Sync Server | Anki sync protocol | 카드 DB 동기화 (클라이언트 ↔ 서버) | 27701 |
| AnkiConnect | HTTP JSON API | 카드 CRUD, 덱 조회 (awesome-anki 웹앱) | 8765 |

두 서비스 모두 Tailscale VPN 내에서만 접근 가능합니다.

**버전**: Anki 25.09.2 / AnkiConnect 25.11.9.0 / Qt 6.10.1 / NixOS 26.05

## 목적과 범위

Anki 동기화 서버와 AnkiConnect API 서버의 배포, 접속, 백업, 장애 복구 절차를 다룬다.

## 모듈 구조

### Anki Sync Server

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `ankiSync` mkOption 정의 |
| `modules/nixos/programs/anki-sync-server/default.nix` | 서비스 설정 (네이티브 모듈 래핑) |
| `modules/nixos/programs/anki-sync-server/backup.nix` | 매일 백업 타이머 (SSD -> HDD) |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `secrets/anki-sync-password.age` | agenix 암호화 비밀번호 |
| `libraries/constants.nix` | 포트 (`ankiSync = 27701`) |

### AnkiConnect (Headless Anki)

| 파일 | 역할 |
|------|------|
| `modules/nixos/options/homeserver.nix` | `ankiConnect` mkOption 정의 |
| `modules/nixos/programs/anki-connect/default.nix` | Headless Anki + AnkiConnect 서비스 |
| `modules/nixos/programs/anki-connect/sync.nix` | 자동 동기화 서비스/타이머 + 상태 파일 |
| `modules/nixos/lib/tailscale-wait.nix` | Tailscale IP 대기 유틸리티 |
| `libraries/constants.nix` | 포트 (`ankiConnect = 8765`) |

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

사용자: `greenhead` / 비밀번호: `sudo cat /run/agenix/anki-sync-password`

### AnkiConnect 서비스 관리

```bash
systemctl status anki-connect.service        # 상태 확인
journalctl -u anki-connect.service -f        # 로그 실시간
curl -s http://100.79.80.95:8765 -X POST \
  -d '{"action":"version","version":6}'      # API 응답 확인

systemctl status anki-connect-sync.service    # 마지막 sync 실행 상태
systemctl status anki-connect-sync.timer      # 주기 sync 타이머 상태
journalctl -u anki-connect-sync.service -f    # sync 로그 실시간
cat /var/lib/anki/sync-status.json            # 마지막 sync 결과(state file)
```

Headless mode (offscreen Qt), 설정은 Nix store에 bake됨. 상세: [references/setup.md](references/setup.md)

### 서비스 활성화/비활성화

```nix
# modules/nixos/configuration.nix
homeserver.ankiSync.enable = true;      # Sync Server 활성화
homeserver.ankiSync.port = 27701;       # 포트 (기본값은 constants.nix)
homeserver.ankiConnect.enable = true;   # AnkiConnect API 활성화
homeserver.ankiConnect.port = 8765;     # 포트 (기본값은 constants.nix)
homeserver.ankiConnect.profile = "server"; # Anki 프로필명
homeserver.ankiConnect.sync = {
  enable = true;            # 자동 sync 활성화
  onStart = true;           # 서비스 시작 시 1회 sync
  interval = "5m";          # 주기 sync (OnUnitActiveSec)
};
```

## 핵심 절차

1. 서비스 상태(`systemctl status anki-sync-server`)와 포트 리스닝을 확인한다.
2. 클라이언트에 self-hosted URL을 적용하고 실제 Sync를 실행한다.
3. 백업 타이머 상태와 백업 파일 생성을 검증한다.
4. 인증/바인딩 오류는 agenix secret과 tailscale-wait 로그로 분리 진단한다.

## 주의사항

- **로그인 UI에 "AnkiWeb" 표시**: 커스텀 sync 서버에서도 로그인 다이얼로그에 "AnkiWeb 아이디"로 표시됨 → 셀프호스팅 자격증명 입력하면 정상 동작

## 자주 발생하는 문제

### Sync Server
1. **Sync 연결 실패**: Tailscale VPN 연결 확인, `ss -tlnp | grep 27701`
2. **인증 실패**: agenix secret 복호화 확인 (`ls -la /run/agenix/anki-sync-password`)
3. **백업 실패**: 소스 디렉토리 비어있으면 안전하게 중단 (의도적 동작)
4. **서비스 시작 실패**: `journalctl -u anki-sync-server.service`로 원인 확인

### AnkiConnect
1. **첫 부팅 무한 대기**: `prefs21.db` 없으면 `NoCloseDiag.exec()` 블로킹 → ExecStartPre에서 DB 사전 생성으로 해결됨
2. **QtWebEngine SIGABRT**: GPU 없는 headless에서 EGL 실패 → `--disable-gpu` 플래그로 해결됨
3. **API 무응답**: `systemctl status anki-connect` → Tailscale IP 대기 실패 가능
4. **덱 목록 비어있음/Default만**: 첫 부팅 bootstrap 실패 가능 → `journalctl -u anki-connect.service`에서 bootstrap 로그 확인
5. **재시작 루프**: `journalctl -u anki-connect -f` → 좀비 프로세스 DB lock 또는 프로필 디렉터리 문제

## 레퍼런스

- 설치/설정 상세: [references/setup.md](references/setup.md)
- 트러블슈팅: [references/troubleshooting.md](references/troubleshooting.md)
