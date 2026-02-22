# Anki 서비스 설치/설정 상세

## 소프트웨어 버전 (2026-02 기준)

| 컴포넌트 | 버전 | 비고 |
|----------|------|------|
| Anki | 25.09.2 | nixpkgs `pkgs.anki` |
| AnkiConnect addon | 25.11.9.0 | `pkgs.ankiAddons.anki-connect` |
| Qt | 6.10.1 | Anki 의존성 |
| NixOS | 26.05 (unstable) | MiniPC 호스트 |
| Python | 3.13.11 | Anki 런타임 |

## NixOS 모듈 옵션

### Anki Sync Server

```nix
# modules/nixos/options/homeserver.nix
ankiSync = {
  enable = lib.mkEnableOption "Anki self-hosted sync server";
  port = lib.mkOption {
    type = lib.types.port;
    default = constants.network.ports.ankiSync;  # 27701
    description = "Port for Anki sync server";
  };
};
```

### AnkiConnect (Headless Anki)

```nix
# modules/nixos/options/homeserver.nix
ankiConnect = {
  enable = lib.mkEnableOption "Headless Anki with AnkiConnect API";
  port = lib.mkOption {
    type = lib.types.port;
    default = constants.network.ports.ankiConnect;  # 8765
    description = "Port for AnkiConnect HTTP API";
  };
  profile = lib.mkOption {
    type = lib.types.str;
    default = "server";
    description = "Anki profile name";
  };
  configApi = {
    enable = lib.mkOption { type = lib.types.bool; default = true; };
    # nonEmptyPrefixList: 비어있는 리스트 불가 + 공백-only 항목 불가
    allowedKeyPrefixes = lib.mkOption { type = nonEmptyPrefixList; default = [ "awesomeAnki." ]; };
    maxValueBytes = lib.mkOption { type = lib.types.ints.positive; default = 65536; };
  };
  sync = {
    enable = lib.mkOption { type = lib.types.bool; default = true; };
    onStart = lib.mkOption { type = lib.types.bool; default = true; };
    interval = lib.mkOption { type = lib.types.str; default = "5m"; };
  };
};
```

**핵심 설계:**
- `pkgs.anki.withAddons` + `withConfig`: 설정이 Nix store에 bake됨 (immutable)
- `QT_QPA_PLATFORM=offscreen`: GUI 없이 Qt 오프스크린 렌더링
- `QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu"`: GPU 없는 headless 환경에서 EGL abort 방지
- 인증: Tailscale 네트워크 격리에 의존 (API key 불필요)
- `prefs21.db` 사전 생성: `ExecStartPre`에서 Python/sqlite3/pickle로 `_global` + profile 엔트리 초기화 → offscreen 모드 `NoCloseDiag` 블로킹 방지
- 프로필 자동 생성: `ExecStartPre`에서 디렉터리 + DB 보장
- sync 설정 addon: profile open 시 custom sync URL/username 적용 + sync key 자동 초기화
- AnkiConnect 커스텀 액션: `getConfig(key)`, `setConfig(key,val)` 제공
- key allowlist: 기본 `awesomeAnki.` prefix만 허용
- 값 크기 제한: UTF-8 JSON 직렬화 기준 64KB
- 로그 민감값 보호: `getConfig/setConfig` 요청/응답의 값(`params.val`, `result`)은 redaction 처리
- 자동 동기화: `anki-connect-sync.service` + `anki-connect-sync.timer` (onStart + 5분 주기)
- 상태 파일: `/var/lib/anki/sync-status.json` (마지막 시도/성공/에러 기록)

## 아키텍처 참고

**openFirewall 비활성**: 네이티브 모듈의 `openFirewall`은 모든 인터페이스에 포트 개방. `trustedInterfaces = [ "tailscale0" ]`가 Tailscale 전체 트래픽 허용하므로 별도 방화벽 룰 불필요. 보안은 Tailscale IP 바인딩(`address = minipcTailscaleIP`)에 의존.

**DynamicUser (Sync Server)**: upstream 모듈이 `DynamicUser = true` 사용. `ExecStartPre`에서 tailscale-wait 실행 시 소켓 접근 불가 → `"+"` prefix로 root 권한 실행.

**데이터 디렉토리**: Sync Server는 `StateDirectory`로 `/var/lib/anki-sync-server/` 자동 관리 (`DynamicUser`). AnkiConnect는 `StateDirectory = "anki"` → `/var/lib/anki/`.

## agenix 시크릿 관리

비밀번호 파일 위치: `secrets/anki-sync-password.age`

```bash
# 비밀번호 생성/변경 (MiniPC에서 실행)
cd ~/Workspace/nixos-config
nix run github:ryantm/agenix -- -e secrets/anki-sync-password.age
# 에디터에서 비밀번호만 입력 (KEY=value 형식 아님, 평문 비밀번호)

# 비밀번호 확인
sudo cat /run/agenix/anki-sync-password
```

NixOS 시스템 레벨 agenix 사용 (`age.secrets.*`). Home Manager 레벨이 아님.

## 클라이언트 URL 형식

- Sync URL: `http://<tailscale-ip>:<port>/`
- 끝에 `/` 슬래시 필수
- Media sync URL: 비워둠 (최신 Anki는 자동으로 같은 URL 사용)
- HTTPS 불필요 (Tailscale이 WireGuard 암호화 제공)

## AnkiWeb에서 마이그레이션

### 순서

1. 모든 기기에서 AnkiWeb에 마지막 동기화
2. macOS Desktop: 커스텀 sync 서버 URL 설정 + Anki 재시작
3. Desktop에서 Sync → **"Upload"** 선택 (로컬 → 서버)
4. `ls -la /var/lib/anki-sync-server/` 에서 사용자 데이터 확인
5. AnkiMobile: 커스텀 sync 서버 URL 설정
6. AnkiMobile에서 Sync → **"Download"** 선택 (서버 → 아이폰)
7. 양쪽 기기에서 카드 수, 덱 목록 일치 확인

### 되돌리기

커스텀 sync 서버 필드를 비우면 AnkiWeb으로 복귀.
AnkiWeb 계정은 백업으로 유지 가능 (동기화만 중단됨).

## backup.colpkg 복원

비상 시 `.colpkg` 파일로 복원:

1. Anki Desktop에서 File > Import
2. `backup.colpkg` 선택
3. Sync → "Upload" 선택

## 백업 구조

- 소스: `/var/lib/anki-sync-server/` (SSD)
- 백업: `/mnt/data/backups/anki/YYYY-MM-DD/` (HDD)
- 보존: 7일
- 스케줄: 매일 04:00 KST

## 검증 기준값 (2025-01 기준)

마이그레이션 후 AnkiConnect API(`http://100.79.80.95:8765`)로 대조:

| 항목 | 기대값 |
|------|--------|
| 총 노트 수 | 811 |
| 총 카드 수 | 980 |
| 총 리뷰 기록 수 | 9,270 |
| 미디어 파일 수 | 1,229 |
| 덱 수 | 15 |
| 태그 수 | 22 |

## Config API 배포 검증 (필수)

1. 옵션/정적 검증:
   - `nix eval --impure --file tests/eval-tests.nix`
2. 빌드 검증:
   - `nix build .#nixosConfigurations.greenhead-minipc.config.system.build.toplevel`
3. 배포 후 스모크:
   - `version` 성공
   - `getConfig` 미존재 key는 `result: null`
   - `setConfig` 후 `getConfig` round-trip 일치
4. 성능 수용 기준(64KB 정책):
   - `sync` 수동 20회 기준 `P95 < 10s`, 실패율 `0%`
