# 트러블슈팅

Atuin 및 Zsh 관련 문제와 해결 방법을 정리합니다.

## 목차

- [zsh-autosuggestion에서 한글/일본어 경로 레이아웃 깨짐](#zsh-autosuggestion에서-한글일본어-경로-레이아웃-깨짐)
- [한글 포함 히스토리 일괄 삭제](#한글-포함-히스토리-일괄-삭제)
- [atuin status가 404 오류 반환](#atuin-status가-404-오류-반환)
- [Encryption key 불일치로 동기화 실패](#encryption-key-불일치로-동기화-실패)
- [Atuin daemon 불안정 (deprecated)](#atuin-daemon-불안정-deprecated)
- [CLI sync (v2)가 last_sync_time 파일 미업데이트](#cli-sync-v2가-last_sync_time-파일-미업데이트)
- [네트워크 문제로 sync 실패](#네트워크-문제로-sync-실패)
- [Fuzzy search로 의도치 않은 검색 결과](#fuzzy-search로-의도치-않은-검색-결과)

---

## zsh-autosuggestion에서 한글/일본어 경로 레이아웃 깨짐

> **발생 시점**: 2026-01-17
> **상태**: 부분 해결 (문자 표시는 정상, 커서 위치는 일부 문제)

**증상**: `cd` 입력 시 한글/일본어가 포함된 경로가 zsh-autosuggestion으로 제안되면 터미널 레이아웃이 깨짐.

```
# 정상 동작 (영어 경로)
~ > cd Documents/projects/  # autosuggestion 정상

# 문제 발생 (한글/일본어 경로)
~ > cd Documents/プロジェクト/한글폴더/  # 레이아웃 깨짐
# 다음과 같이 표시됨:
# cd Documents/プロシ<3099>ェクト/한글폴더/  # <3099> 문자 노출, 커서 위치 틀어짐
```

**원인**: macOS 파일 시스템(APFS/HFS+)의 NFD(분해형) 유니코드 정규화.

| 정규화 | 예시 | 바이트 |
| ------ | ---- | ------ |
| NFC (조합형) | `동` | `EB 8F 99` (3바이트) |
| NFD (분해형) | `ᄃ` + `ᅩ` + `ᆼ` | `E1 84 83 E1 85 A9 E1 86 BC` (9바이트) |

macOS는 파일명을 NFD로 저장하므로:
- 한글: `동` -> `ᄃ` + `ᅩ` + `ᆼ` (초성+중성+종성 분리)
- 일본어: `ダ` -> `タ` + U+3099 (기본자+탁점 분리)

zsh-autosuggestion이 결합 문자(combining character)의 너비를 잘못 계산하여 커서 위치가 틀어짐.

**진단 방법**:

```bash
# 1. 파일명 인코딩 확인
ls Documents/プロジェクト | xxd | head -10
# NFD면 한글이 초성/중성/종성 바이트로 분리됨

# 2. grep으로 NFC/NFD 차이 확인
ls Documents | grep 한글  # NFC "한글"로 검색
# NFD로 저장된 경우 매칭 안 됨!
```

**해결 방법**:

**1. `setopt COMBINING_CHARS` 추가 (핵심)**

zsh 4.3.9부터 도입된 내장 옵션으로, 결합 문자를 기본 문자와 같은 화면 영역에 표시.

```nix
# modules/shared/programs/shell/default.nix
programs.zsh = {
  initContent = lib.mkMerge [
    (lib.mkBefore ''
      # macOS NFD 유니코드 결합 문자 처리 (한글 자모 분리, 일본어 dakuten 등)
      setopt COMBINING_CHARS

      # ... 나머지 설정
    '')
  ];
};
```

**2. autosuggestion 설정 조정 (보조)**

```nix
programs.zsh = {
  autosuggestion = {
    enable = true;
    highlight = "fg=#808080";
    strategy = [ "history" ];  # completion 제외로 cursor 버그 완화
  };
};
```

> **주의**: `strategy = [ "history" ]`는 Tab completion 기반 제안을 비활성화함 (한 번도 실행 안 한 명령어는 제안 안 됨).

**적용 후 확인**:

```bash
# setopt 적용 확인
setopt | grep -i combining  # 출력: combiningchars

# 문자 표시 테스트
echo "テスト 한글"  # 정상 출력되는지 확인
```

**결과**:

| 항목 | 적용 전 | 적용 후 |
| ---- | ------- | ------- |
| 문자 표시 | `タ<3099>` | `ダ` (정상) |
| 커서 위치 | 틀어짐 | 일부 개선 (완전하지 않음) |

**알려진 제한사항**:

- 커서 위치 계산은 zsh-autosuggestions 플러그인 자체 로직의 한계로 완전히 해결되지 않음
- 문제가 심할 경우 `ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=50`으로 긴 경로 제안 제한 검토
- Atuin TUI에서 NFD 한글이 초성만 표시되는 문제는 Ratatui 라이브러리 버그 (업스트림 패치 대기)

**참고 자료**:

- [zsh FAQ - COMBINING_CHARS](https://zsh.sourceforge.io/FAQ/zshfaq05.html)
- [Home Manager - zsh.autosuggestion 옵션](https://mynixos.com/home-manager/options/programs.zsh.autosuggestion)
- [Oh My Zsh - macOS NFD issue #12380](https://github.com/ohmyzsh/ohmyzsh/issues/12380)
- [Ratatui - Korean rendering #1396](https://github.com/ratatui/ratatui/issues/1396)

---

## 한글 포함 히스토리 일괄 삭제

> **발생 시점**: 2026-01-27
> **환경**: atuin 18.11.0, zsh-autosuggestions 0.7.1 (nixpkgs)
> **상태**: 해결 (SQLite 직접 삭제)

**증상**: zsh-autosuggestion이 한글이 포함된 명령어(예: git commit 한글 메시지)를 제안할 때 터미널 TUI 렌더링이 깨짐.

```
# 이런 히스토리가 autosuggestion으로 제안되면 TUI가 깨짐
git commit -m 'fix(qa): [날씨] 날씨 페이지에서 하단 버튼 클릭...'
```

**근본 원인**: **zsh-autosuggestions** 플러그인이 한글(멀티바이트 유니코드) 문자의 너비를 잘못 계산하여 TUI 렌더링이 깨짐. Atuin 자체의 문제가 아님에 주의.

**해결 방법**: Atuin 히스토리 DB에서 한글 포함 항목을 일괄 삭제.

### 사전 확인

```bash
# 삭제 대상 미리보기 (기본 출력에서 한글 항목 필터링)
atuin history list 2>/dev/null | \
  perl -C -ne 'print if /[\x{AC00}-\x{D7AF}\x{3130}-\x{318F}\x{1100}-\x{11FF}]/' | wc -l
```

### `atuin history delete` 서브커맨드 부재 (v18.11.0)

atuin 18.11.0에는 `atuin history delete` 서브커맨드가 존재하지 않음.

```bash
$ atuin history --help
# 사용 가능한 커맨드: start, end, list, last, init-store, prune, dedup
# "delete"는 없음
```

`atuin search --delete "<쿼리>"` 명령이 존재하지만, 정규식을 지원하지 않아 "한글이 포함된 모든 항목"을 한 번에 매칭할 수 없음. 따라서 SQLite DB 직접 수정이 필요.

### SQLite 직접 삭제 (권장)

```bash
# 1. 반드시 백업 먼저
cp ~/.local/share/atuin/history.db ~/.local/share/atuin/history.db.bak

# 2. Python 스크립트로 한글 포함 항목 삭제
python3 -c "
import sqlite3, re, os
conn = sqlite3.connect(os.path.expanduser('~/.local/share/atuin/history.db'))
cur = conn.cursor()
cur.execute('SELECT id, command FROM history')
p = re.compile(r'[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]')
ids = [r[0] for r in cur.fetchall() if p.search(r[1] or '')]
print(f'삭제 대상: {len(ids)}개')
for i in ids:
    cur.execute('DELETE FROM history WHERE id = ?', (i,))
conn.commit()
conn.close()
print('완료')
"
```

**정규식 매칭 범위**:

| 유니코드 범위 | 설명 |
|---------------|------|
| `\uAC00-\uD7AF` | 한글 음절 (가~힣) |
| `\u1100-\u11FF` | 한글 자모 (초성·중성·종성) |
| `\u3130-\u318F` | 한글 호환 자모 (ㄱ~ㅎ, ㅏ~ㅣ) |

### 주의사항

- **백업 필수**: SQLite DB를 직접 수정하므로, 반드시 `.bak` 파일로 백업 후 진행
- **Sync 서버 미반영**: SQLite 직접 삭제는 로컬 DB만 수정. sync 서버에는 반영되지 않을 수 있음. 삭제 후 `atuin sync` 실행 권장
- **재발 방지**: 한글이 포함된 명령어(예: git commit 한글 메시지)를 계속 사용하면 다시 쌓임. 근본적 해결은 zsh-autosuggestions 업스트림 패치 필요

### 실행 결과 (2026-01-27)

| 항목 | 값 |
|------|-----|
| 삭제 전 히스토리 | 55,172개 |
| 삭제 대상 | 1,963개 |
| 삭제 후 히스토리 | 53,210개 |

---

## atuin status가 404 오류 반환

> **발생 시점**: 2026-01-13 / atuin 18.10.0, 18.11.0 모두 동일

**증상**: `atuin status` 명령 실행 시 404 오류 발생. `atuin sync`는 정상 작동.

```
Error: There was an error with the atuin sync service: Status 404.
If the problem persists, contact the host

Location:
    .../api_client.rs:186:9
```

**원인**: Atuin 클라우드 서버(`api.atuin.sh`)가 **Sync v1 API를 비활성화**했기 때문입니다.

소스 코드 분석 결과 (`crates/atuin-server/src/router.rs`):

```rust
// Sync v1 routes - can be disabled in favor of record-based sync
if settings.sync_v1_enabled {
    routes = routes
        .route("/sync/status", get(handlers::status::status))
        // ... 다른 v1 라우트들
}
```

`/sync/status` 엔드포인트는 `sync_v1_enabled = true`일 때만 활성화됩니다. Atuin 클라우드 서버에서 이 설정을 비활성화하면서 404가 반환됩니다.

**영향 범위**:

| 명령어 | 사용 API | 상태 |
|--------|----------|------|
| `atuin sync` | v2 (`/api/v0/*`) | O 정상 |
| `atuin doctor` | 로컬 + 서버 | O 정상 |
| `atuin status` | v1 (`/sync/status`) | X 404 |

**해결**: 클라이언트에서 해결할 수 없음. Atuin 팀의 업데이트 필요.

**현재 상태**: `atuin status`는 정보 표시용이므로 **실제 동기화 기능에 영향 없음**. 무시해도 됩니다.

**동기화 상태 확인 방법**:

```bash
# atuin doctor 사용 (권장)
atuin doctor 2>&1 | grep -o '"last_sync": "[^"]*"'
# 예: "last_sync": "2026-01-13 8:12:42.22629 +00:00:00"

# watchdog 스크립트 수동 실행
awd
```

> **주의**: atuin CLI sync (v2)는 `last_sync_time` 파일을 업데이트하지 않는 버그가 있습니다. 현재 설정에서는 launchd의 `com.green.atuin-sync` 에이전트가 sync 성공 후 직접 파일을 업데이트합니다. 자세한 내용은 [CLI sync (v2)가 last_sync_time 파일 미업데이트](#cli-sync-v2가-last_sync_time-파일-미업데이트)를 참고하세요.

---

## Encryption key 불일치로 동기화 실패

**증상**: `atuin sync` 실행 시 key 불일치 오류 발생

```
Error: attempting to decrypt with incorrect key.
currently using k4.lid.XXX..., expecting k4.lid.YYY...
```

**원인**: 서버에 저장된 히스토리가 다른 encryption key로 암호화되어 있음. 주로 다음 상황에서 발생:

1. 새 계정 생성 시 새 key가 자동 생성됨
2. 다른 기기에서 다른 key를 사용 중
3. key 파일을 백업하지 않고 재설치

**해결**:

**방법 1: 기존 key 복원** (기존 히스토리 유지)
```bash
# 백업된 key가 있는 경우
cp ~/.local/share/atuin/key.backup ~/.local/share/atuin/key
atuin sync
```

**방법 2: 완전히 새로 시작** (히스토리 포기)
```bash
# 모든 atuin 데이터 삭제
rm -rf ~/.local/share/atuin

# 새 계정 등록
atuin register -u <username> -e <email>
```

**예방**: key 파일을 안전한 백업 위치에 보관

```bash
# key 백업
cp ~/.local/share/atuin/key ~/.local/share/atuin/key.backup-$(date +%Y%m%d)
```

> **참고**: Atuin 모니터링 시스템은 `modules/darwin/programs/atuin/` 및 `modules/darwin/programs/hammerspoon/files/atuin-menubar.lua`에서 구현됩니다.

---

## Atuin daemon 불안정 (deprecated)

> **발생 시점**: 2026-01-14
> **해결**: daemon 비활성화, launchd로 대체

**증상**: daemon 프로세스가 불안정하게 동작. exit code 1로 반복 종료되거나, 실행 중이지만 sync를 수행하지 않음.

```bash
# launchd 상태 확인
launchctl print gui/$(id -u)/com.green.atuin-daemon
# 결과: runs = 218, last exit code = 1  ← 218번 재시작, 에러로 종료
```

**원인**: atuin daemon은 아직 experimental 기능으로, 다음과 같은 문제가 있음:

- 장시간 실행 시 좀비 상태로 전환
- 네트워크 연결 불안정 시 복구 실패
- 시스템 슬립/웨이크 후 복구 실패
- CLI sync (v2)와 달리 save_sync_time() 호출 로직이 있으나 실제로 동작하지 않는 경우 있음

**해결**: daemon 대신 launchd로 주기적 sync 실행

```nix
# modules/darwin/programs/atuin/default.nix
launchd.agents.atuin-sync = {
  enable = true;
  config = {
    Label = "com.green.atuin-sync";
    ProgramArguments = [
      "/bin/bash" "-c"
      "atuin sync && printf '%s' \"$(date -u +'%Y-%m-%dT%H:%M:%S.000000Z')\" > ~/.local/share/atuin/last_sync_time"
    ];
    RunAtLoad = true;
    StartInterval = 120;  # 2분마다
  };
};
```

**현재 상태**:

| 에이전트 | 상태 | 역할 |
| -------- | ---- | ---- |
| `com.green.atuin-daemon` | 삭제됨 | - |
| `com.green.atuin-sync` | 활성화 | 2분마다 sync |
| `com.green.atuin-watchdog` | 활성화 | 10분마다 상태 체크 |

---

## CLI sync (v2)가 last_sync_time 파일 미업데이트

> **발생 시점**: 2026-01-14
> **상태**: atuin 버그, 우회 적용

**증상**: `atuin sync` 명령이 성공해도 `~/.local/share/atuin/last_sync_time` 파일이 업데이트되지 않음.

```bash
$ cat ~/.local/share/atuin/last_sync_time
2026-01-13T12:57:07.715542Z  # 어제 시간

$ atuin sync
0/0 up/down to record store
Sync complete! 51888 items in history database, force: false

$ cat ~/.local/share/atuin/last_sync_time
2026-01-13T12:57:07.715542Z  # 여전히 어제 시간!
```

**원인**: atuin 소스코드 분석 결과, CLI sync (v2)에서 `save_sync_time()` 함수가 호출되지 않음.

```rust
// crates/atuin/src/command/client/sync.rs
// sync.records = true (v2) 경로에서 save_sync_time() 미호출
pub async fn run(...) -> Result<()> {
    if settings.sync.records {
        // v2 sync - save_sync_time() 없음!
        sync::sync(&settings, &db).await?;
    } else {
        // v1 sync - save_sync_time() 있음
        atuin_client::sync::sync(&settings, false, &db).await?;
    }
}
```

**해결**: launchd에서 sync 성공 후 직접 파일 업데이트

```bash
atuin sync && printf '%s' "$(date -u +'%Y-%m-%dT%H:%M:%S.000000Z')" > ~/.local/share/atuin/last_sync_time
```

**주의사항**:

- 줄바꿈 없이 작성해야 함 (`echo` 대신 `printf '%s'`)
- UTC 시간으로 작성해야 함 (`date -u`)
- 형식: `YYYY-MM-DDTHH:MM:SS.000000Z`

---

## 네트워크 문제로 sync 실패

> **발생 시점**: 2026-01-14

**증상**: 회사 네트워크 등에서 sync가 실패하지만 원인을 알 수 없음.

**원인**: 기존 watchdog이 에러를 무시(`2>/dev/null`)하고, 네트워크 상태를 확인하지 않았음.

**해결**: watchdog에 네트워크 확인 및 로깅 추가

```bash
# 네트워크 확인 (DNS + HTTPS)
host api.atuin.sh
curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://api.atuin.sh

# 로그 확인
tail -f ~/.local/share/atuin/watchdog.log
```

**로그 파일**: `~/.local/share/atuin/watchdog.log`

```
[2026-01-14 11:29:51] [INFO] === Atuin Watchdog ===
[2026-01-14 11:29:51] [INFO] Host: work-MacBookPro
[2026-01-14 11:29:51] [INFO] Checking network to api.atuin.sh...
[2026-01-14 11:29:51] [ERROR] DNS resolution failed for api.atuin.sh
[2026-01-14 11:29:51] [ERROR] Network issue detected - skipping recovery
```

> **참고**: 자동 복구 기능은 `modules/darwin/programs/atuin/files/atuin-watchdog.sh`에서 구현됩니다.

---

## Fuzzy search로 의도치 않은 검색 결과

> **발생 시점**: 2026-01-18 / atuin 18.11.0
> **해결**: `search_mode = "fulltext"` 설정

**증상**: `atuin search "media"` 실행 시 `media`라는 문자열이 온전히 포함되지 않은 결과도 표시됨.

```bash
$ atuin search "media"
2025-09-12 10:47:41     rm -rf ~/Library/Developer/Xcode/DerivedData/   # media가 없는데?
2025-12-21 17:29:38     sudo nix run ... nix-darwin -- switch --flake . # 이것도?
```

**원인**: Atuin의 기본 `search_mode`가 `fuzzy`이기 때문입니다. Fuzzy 검색은 입력한 글자(`m`, `e`, `d`, `i`, `a`)가 **순서대로 흩어져 있기만 하면** 매칭됩니다.

예: `rm -rf ~/Library/Developer/Xcode/DerivedData/`
- **m**: r**m**
- **e**: D**e**veloper
- **d**: **D**erived**D**ata
- **i**: L**i**brary
- **a**: Dat**a**

**해결**: `search_mode`를 `fulltext`로 변경

```nix
# modules/shared/programs/shell/default.nix
programs.atuin.settings = {
  # ... 기존 설정 ...
  search_mode = "fulltext";
};
```

**왜 `fulltext`인가?**

| 모드 | 특징 | 한계 |
|------|------|------|
| `fuzzy` (기본값) | 글자가 순서대로 흩어져 있으면 매칭 | 의도치 않은 결과 다수 포함 |
| `prefix` | 검색어로 **시작**하는 명령어만 검색 | `sudo media...` 검색 불가 |
| `fulltext` | 검색어가 **정확히 포함**된 명령어만 검색 | 가장 균형 잡힌 선택 |

**TUI에서 모드 변경**: `Ctrl+r` 누르면 모드 순환 (Fuzzy -> Prefix -> Fulltext -> Skim)
