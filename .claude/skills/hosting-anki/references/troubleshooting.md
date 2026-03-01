# Anki 서비스 트러블슈팅

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

---

# AnkiConnect (Headless Anki) 트러블슈팅

## 첫 부팅 시 무한 대기 (NoCloseDiag blocking)

### 증상
서비스가 `active (running)` 상태이나 포트 8765가 리스닝되지 않음.
`strace`로 보면 프로세스가 완전히 idle (Tasks: 1). `ss -tlnp | grep 8765` 결과 없음.

### 원인
`prefs21.db` 미존재 시 Anki 부트 시퀀스:
1. `_loadMeta()` → `firstTime=True` (DB 없음)
2. `_ensureProfile()` → "User 1" 프로필 생성
3. `openProfile("server")` → "server" 프로필 없음 → `invalid_profile_provided=True`
4. `setDefaultLang()` → `NoCloseDiag(QDialog).exec()` → **영구 블로킹**

`NoCloseDiag`는 `reject()`를 `pass`로 오버라이드하므로 offscreen 모드에서 닫을 수 없음.

### 해결 (현재 적용됨)
`ExecStartPre`에서 `prefs21.db`를 Python/sqlite3/pickle로 사전 생성:
- `_global` 엔트리: `firstRun=False`, `defaultLang='en_US'`
- `server` 프로필 엔트리: 기본 설정값

코드: `modules/nixos/programs/anki-connect/default.nix`의 `anki-ensure-profile` 스크립트.

### 버전
Anki 25.09.2 / Qt 6.10.1에서 확인. `aqt/profiles.py` `setDefaultLang()` (line 465-500).

## QtWebEngine EGL 초기화 실패 (SIGABRT)

### 증상
서비스가 시작 후 수 초 내에 `SIGABRT`(signal 6)로 크래시.
`journalctl`에서 Tasks가 28까지 증가 후 종료.

### 원인
`QT_QPA_PLATFORM=offscreen`이어도 QtWebEngine의 내장 Chromium이 GPU 컨텍스트 생성을 시도:
1. `SurfaceFactoryQt::GetGLOzone()` → EGL display 초기화
2. 모든 EGL display type 실패 → `QMessageLogger::fatal()` → `abort()`

### 해결 (현재 적용됨)
```nix
environment.QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";
```
소프트웨어 렌더링으로 폴백. `modules/nixos/programs/anki-connect/default.nix`에 적용.

### 버전
Anki 25.09.2 / Qt 6.10.1 / NixOS 26.05에서 확인.

## API 무응답

### 증상
`curl http://100.79.80.95:8765` 연결 실패 또는 타임아웃

### 진단
```bash
# 1. 서비스 상태 확인
systemctl status anki-connect.service

# 2. Tailscale IP 리스닝 확인
ss -tlnp | grep 8765

# 3. 로그에서 에러 확인
journalctl -u anki-connect.service --since today --no-pager

# 4. Tailscale 연결 확인
tailscale status
```

### 일반적인 원인
1. **Tailscale IP 미할당**: tailscale-wait가 60초 대기 후 timeout
2. **프로필 디렉터리 문제**: ExecStartPre에서 생성 실패
3. **메모리 초과**: `MemoryMax=512M` 도달 → OOMKilled

### 해결
- Tailscale 연결 확인: `tailscale up`
- 서비스 재시작: `sudo systemctl restart anki-connect`
- OOM 확인: `journalctl -u anki-connect.service | grep -i oom`

## 덱 목록 비어있음 / Default만 표시

### 증상
`deckNames` API가 빈 배열 `[]` 또는 `["Default"]`만 반환.

### 원인
AnkiConnect의 `server` 프로필에 컬렉션 데이터가 없음. 두 가지 경우:
1. **첫 배포**: 프로필이 빈 상태로 생성됨 (ExecStartPre가 디렉터리만 보장)
2. **좀비 프로세스 DB lock**: 이전 Anki 프로세스가 `collection.anki2` 잠금을 보유 중이면 새 프로세스가 빈 컬렉션으로 시작

### 진단
```bash
# 프로필 컬렉션 크기 확인 (빈 DB는 ~140KB)
du -h /var/lib/anki/.local/share/Anki2/server/collection.anki2

# 좀비 프로세스 확인
pgrep -a anki  # anki-sync-server 외 2개 이상이면 좀비 의심
```

### 해결 (Sync Server → AnkiConnect 컬렉션 복사)
```bash
# 1. 서비스 중지 + 좀비 프로세스 정리
sudo systemctl stop anki-connect.service
sudo kill -9 $(pgrep -f '.anki-wrapped') 2>/dev/null

# 2. lock/WAL 파일 정리
sudo rm -f /var/lib/anki/.local/share/Anki2/server/{.lock,collection.anki2-wal,collection.anki2-shm}

# 3. Sync Server 컬렉션 복사
sudo cp /var/lib/anki-sync-server/greenhead/collection.anki2 \
  /var/lib/anki/.local/share/Anki2/server/collection.anki2

# 4. 미디어 파일 복사
sudo bash -c 'cp /var/lib/anki-sync-server/greenhead/media/* \
  /var/lib/anki/.local/share/Anki2/server/collection.media/'

# 5. 권한 복원 + 재시작
sudo chown -R anki:anki /var/lib/anki/.local/share/Anki2/server/
sudo systemctl start anki-connect.service
```

**참고**: 현재는 `anki-connect` 시작 시 bootstrap + 주기 sync가 기본 동작입니다.
위 절차는 bootstrap이 실패했거나 lock 손상 시 사용하는 수동 복구 경로입니다.

## 서비스 재시작 루프

### 증상
`systemctl status`에서 `activating (auto-restart)` 반복

### 진단
```bash
# 최근 실패 원인 확인
journalctl -u anki-connect.service --since today --no-pager | tail -50

# 프로필 디렉터리 확인
ls -la /var/lib/anki/.local/share/Anki2/server/
```

### 일반적인 원인
1. **offscreen 렌더링 실패**: Qt 관련 라이브러리 누락
2. **프로필 잠금**: 이전 프로세스가 DB lock을 해제하지 않음
3. **addon 로드 실패**: withAddons 설정 문제

### 해결
- Qt 라이브러리 확인: 로그에서 `qt.qpa` 관련 메시지 확인
- 프로필 잠금 해제: `/var/lib/anki/.local/share/Anki2/server/.lock` 파일 확인/삭제
- `nrs` 재배포로 addon 설정 재생성

## CORS 에러

### 증상
awesome-anki 웹 앱에서 AnkiConnect API 호출 시 브라우저 콘솔에 CORS 에러

### 원인
`webCorsOriginList`에 요청 Origin이 포함되지 않음.

### 해결
**참고**: awesome-anki는 Hono 서버가 AnkiConnect를 프록시하므로 브라우저 → AnkiConnect 직접 호출은 발생하지 않음. CORS 에러가 보이면 프록시 경로 확인.

현재 허용 Origin 목록 (Nix store에 bake됨):
- `http://localhost`
- `http://localhost:3000`
- `http://localhost:5173`
- `http://100.79.80.95`

변경 시 `modules/nixos/programs/anki-connect/default.nix`의 `webCorsOriginList` 수정 후 `nrs` 재배포.

## `getConfig`/`setConfig`가 `unsupported action` 반환

### 증상
`version`은 정상인데 `getConfig` 또는 `setConfig`가 `unsupported action`.

### 진단
```bash
# 1) 서비스 버전 확인
curl -s http://100.79.80.95:8765 -X POST -H 'Content-Type: application/json' \
  -d '{"action":"version","version":6}'

# 2) 커스텀 액션 확인
curl -s http://100.79.80.95:8765 -X POST -H 'Content-Type: application/json' \
  -d '{"action":"getConfig","version":6,"params":{"key":"awesomeAnki.prompts.system"}}'

# 3) 배포 산출물 빌드 확인 (패치 컴파일 단계)
nix build .#nixosConfigurations.greenhead-minipc.config.system.build.toplevel
```

### 해결
1. `modules/nixos/programs/anki-connect/addons/anki-connect-config-actions.patch` 적용 여부 확인
2. `homeserver.ankiConnect.configApi.enable = true` 확인
3. `nrs` 재배포 후 `systemctl restart anki-connect.service`

## `config key is not allowed` 오류

### 원인
요청 key가 `homeserver.ankiConnect.configApi.allowedKeyPrefixes` 범위 밖.

### 해결
- key를 `awesomeAnki.` prefix로 변경
- 또는 Nix 옵션에 필요한 prefix를 추가 후 재배포

## `config API is disabled` 오류

### 원인
- `homeserver.ankiConnect.configApi.enable = false`
- 또는 addon config 계약 키 누락/불일치로 fail-closed 동작

### 해결
1. `homeserver.ankiConnect.configApi.enable = true` 확인
2. `modules/nixos/programs/anki-connect/default.nix`의 config key 이름과 patch 상수 계약 일치 확인
3. `nrs` 재배포 후 `systemctl restart anki-connect.service`
4. `nix eval --impure --file tests/eval-tests.nix`로 계약 테스트(allowed prefixes/max bytes 정합성) 통과 확인

## `config API settings are invalid` 오류

### 원인
- addon config가 dict가 아니거나 key 타입이 손상됨
- `allowedKeyPrefixes`/`maxValueBytes`가 비정상 타입으로 오염됨

### 해결
1. Nix 옵션 타입 제약(`nonEmptyPrefixList`, `ints.positive`) 위반 여부 확인
2. `nix eval --impure --file tests/eval-tests.nix` 실행
3. `nix build .#nixosConfigurations.greenhead-minipc.config.system.build.toplevel`로 patch/config 적용 검증

## `invalid config key` 오류

### 원인
- `key`가 문자열이 아님
- `key`가 빈 문자열이거나 공백-only 문자열

### 해결
- 요청 payload에서 `params.key`를 non-empty 문자열로 전달
- 예: `\"awesomeAnki.prompts.system\"`

## `config value exceeds size limit` 오류

### 원인
직렬화된 JSON payload가 `maxValueBytes`(기본 64KB) 초과.

### 해결
1. 저장 payload 크기 축소
2. 운영 정책상 필요 시 `maxValueBytes` 조정 후 재배포
3. 조정 후 `sync` 20회 측정 기준(`P95 < 10s`, 실패율 0%) 재검증

## `invalid config value` 오류

### 원인
- `setConfig` 요청에서 `val` 누락
- JSON 직렬화 불가능한 값 포함
- `Infinity`/`NaN` 등 비정상 수치 입력

### 해결
- `params.val`을 JSON 직렬화 가능한 값으로 전달
- 직렬화 전 payload를 검증하고 비정상 수치/타입 제거

## 로그에 프롬프트 본문이 보이는지 확인 (보안 점검)

### 진단
```bash
journalctl -u anki-connect.service --since today | grep -E "getConfig|setConfig|prompts.system"
```

### 기대 결과
- 요청/응답 로그에 실제 값 본문이 아닌 redacted 값만 보여야 함
- 본문이 보이면 즉시 롤백:
  1) `homeserver.ankiConnect.configApi.enable = false`
  2) `nrs`
  3) `systemctl restart anki-connect.service`

## AnkiConnect 로그 확인

```bash
# 실시간 로그
journalctl -u anki-connect.service -f

# 오늘 로그에서 에러만
journalctl -u anki-connect.service --since today | grep -i error

# API 응답 테스트
curl -s http://100.79.80.95:8765 \
  -X POST -d '{"action":"version","version":6}'
# 기대: {"result":6,"error":null}
```
