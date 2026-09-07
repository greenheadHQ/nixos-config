# Plan 030: headless Anki 복원 + AnkiWeb 동기화·알림 + 원격 MCP 서버

> **Executor instructions**: 이 plan은 **에이전트 구현 + 운영자 게이트 혼합 runbook**이다.
> 시작 전에 이 파일과 이슈 #1306을 끝까지 읽는다. Step 순서를 지키고, 각 검증 명령의
> 기대 결과를 확인한 뒤 다음으로 간다. **STOP conditions 발생 시 즉시 중단·보고 — 임의
> 진행 금지.** 운영자 게이트(🔒 표시)는 운영자가 수행하며 에이전트는 결과만 검증한다.
> 완료 시 `plans/README.md`의 030 상태 행을 갱신한다.
>
> **Drift check (run first)**: `git log --oneline -1 origin/main` 이 아래 Base snapshot과
> 다르면 `git diff --stat <snapshot>..origin/main -- modules/nixos/programs/anki-host
> modules/nixos/programs/anki-mcp modules/nixos/programs/tailscale.nix
> modules/nixos/options/homeserver.nix libraries/constants.nix tests/eval-tests.nix`로
> 대상 파일 변경을 확인하고 Current state와 대조한다. MiniPC 실측은 아래 "재개 절차"의
> 상태 조회 명령으로 한다. 불일치 시 STOP.

## Status

- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/1306 (epic #973 sub-issue)
- **사용자 관점 정본**: https://github.com/greenheadHQ/anki-study/issues/3 (비공개)
- **Branch**: `feat/anki-mcp-host` (worktree `.claude/worktrees/feat_anki-mcp-host`)
- **Base snapshot**: `origin/main@74a9d158663c04def57d003cff059e51ecf0c688`
- **Priority**: P1
- **Effort**: L (PR 2개)
- **Risk**: HIGH — 실제 학습 컬렉션을 MiniPC로 내려받고, 이 저장소 최초의 인터넷 공개 입구와 인증 코드를 추가한다
- **Depends on**: 024 (soft — AnkiWeb 계정·서버 컬렉션이 존재해야 Download 가능)
- **Category**: feature (철거 결정 #863의 AnkiConnect 부분 되돌림 — CIR 필수)
- **Planned at**: commit `74a9d158`, 2026-09-06
- **Execution**: IN PROGRESS — PR 1 구현·MiniPC 배포·격리 검증(Step 1~13 중 DA 반영까지) 완료, Step 14 운영자 게이트 대기
- **Plan DA**: R1 COMPLETE (finding 21건 전부 CONFIRMED·반영, 롤아웃 계약 2건은 운영자 결정 "계획을 구현에 맞춰 갱신"), R2 COMPLETE (finding 19건 전부 CONFIRMED·반영 — 방향 모드 제거, 복원 절차 계약, sync 계층 단일화, 타임아웃 단일 소스, lab 폐기 절차), R3 COMPLETE (16건: 15 CONFIRMED·1 NOT_AN_ISSUE — 14건 반영: 준비·재시도 상수 단일 소스와 유닛 예산 재계산, /status 즉시 응답 분리, import 구성 시점 게이트, export 덮어쓰기 거부, 복구점 미러·정리 코드 PR 2b로 이관, 인스턴스 enable 옵션 제거, result 어휘 표; 1건 REPLAN_REQUIRED(MCP 유저·상태 파일 접근)는 #1306에 배출), R4 COMPLETE (19건 전부 CONFIRMED·반영 — lab 수명을 PR 2b까지로, 준비됨=로그인 판정 확정, /status 투영 축소, running 상태·요청–결과 대응, busy 예산 스크립트 전체 1회·백오프 합 파생, 애드온 타임아웃 전부 env, allowImport 옵션+배타 assertion, user·profile 옵션 제거, 미디어 대기 제거, 문서 정합). 재검증 라운드(R5) 대기
- **PR DA**: PENDING (PR 1·PR 2 각각 FULL, Opus 5 전용 — 운영자 지시: Codex quota 없음)

## Why this matters

카드 관리 API가 Mac의 loopback AnkiConnect뿐이라 Mac이 꺼지면 어떤 AI 클라이언트도 카드를
다룰 수 없다. ChatGPT Chat은 클라우드에서만 실행되므로 상시 호스트·공개 HTTPS 입구·OAuth가
함께 필요하다. 운영자의 최우선 목표는 "작더라도 매일 공부하는 습관"이며, 이 작업은 그 습관을
방해하지 않는 인프라(눈에 보이는 UI 없음)로 한정한다. 과거 awesome-anki가 "학습 0회, 도구
개발만" 패턴으로 무너진 회고(#711)를 기억하되, 운영자 결정으로 별도 습관 보호 장치는 두지
않는다(이슈 #1306 결정 표).

## Current state (2026-09-06 실측)

- MiniPC: NixOS, Anki·cloudflared 없음, Caddy는 tailnet IP 전용, `allowedTCPPorts` 빈 목록,
  Funnel/Tunnel 흔적 0건. Funnel capability 미부여. `/var/lib/private/anki-sync-server`에
  203MB 잔재(plan 026 Part C STOP, 건드리지 않음). 과거 `anki` 시스템 계정은 #863 이후 정리
  여부 미확인 — 이번 유저는 `anki-host`로 이름을 달리해 충돌을 피한다.
- Mac: Anki 26.05, AnkiConnect loopback 8765, 프로필 `greenheadHQ`, AnkiWeb 동기화 이행 완료.
- 핀된 nixpkgs: `anki` 25.09.4(withAddons), `ankiAddons.anki-connect`, `python3Packages.mcp` 1.27.1.
  Anki 25.09.4↔26.05는 sync 프로토콜 11·스키마 18 동일.
- 과거 구현: `git show 61dadbe1^:modules/nixos/programs/anki-connect/{default,sync}.nix`,
  `git show 61dadbe1^:.claude/skills/hosting-anki/references/troubleshooting.md`.
- 개인 저장소 PoC: anki-study `experiments/anki-plugin-lab/`(FastMCP, NoAuth, 합성 데이터) —
  도구 계약·멱등·승인 UI 관측의 근거. 코드는 재작성한다.
- PR 1 배포 실측(2026-09-06 23:40~): `anki-host-lab`·`anki-host-main` active, lab에 실제 이력
  fixture(노트 856·카드 1025·revlog 9352·미디어 1229) import 후 카운트 일치, export·HDD 백업·
  자격 없는 sync의 조용한 종료·실제 이력 카드 수정 후 ID/일정/revlog 보존 확인.

## Decisions

결정 14건의 정본은 이슈 #1306 "결정" 표다. 구현에 직접 걸리는 불변식만 여기에 둔다.

1. AnkiConnect는 loopback 전용, API 키 없음(Nix store bake 시 평문 노출). MCP 서버만 접근.
2. sync는 애드온이 `col.sync_collection`을 직접 호출한다. AnkiConnect `sync` 액션(GUI 다이얼로그)은 쓰지 않는다.
3. full sync 방향 결정은 헬퍼에 하나뿐이다: 로컬이 비어 있고 서버가 있을 때의 Download — **운영자가 부트스트랩
   유닛을 명시 실행할 때만** (타이머는 빈 컬렉션의 full sync 요구를 알림 없이 `bootstrap-pending`으로 기록).
   서버를 덮어쓰는 Upload 모드는 헬퍼에 존재하지 않는다 — loopback은 이 호스트에서 격리를 보장하지 않고
   (`--network=host` 컨테이너 공유) 되돌릴 수 없는 동작을 무인증 엔드포인트에 두지 않는다. 그 외 full sync 요구는 중단·알림.
   full sync를 유발하는 도구(노트 타입 구조 변경 등, 운영자 결정 "고지·동의 후 실행")는 PR 2b에서 노출하며, 그 전에
   Upload 경로를 root 소유 1회용 승인 파일 게이트 + 사전 검사(직전 성공 sync 스냅샷 대비 노트·revlog 감소 없음,
   복구점 생성 성공)와 함께 별도 설계한다. MCP "지금 동기화"는 mode를 클라이언트 인자로 받지 않는다(normal 고정).
4. 알림 본문에 카드 내용·자격·토큰을 넣지 않는다. 한국어.
5. 서버 코드에 개인 학습 규칙(덱 이름·태그·배치 규칙)을 넣지 않는다. 범용 도구.
6. Funnel은 MCP 포트(443)만. 승인 화면은 8443 serve(tailnet 전용). 인바운드 방화벽 포트는 열지 않는다.
7. overlay 없이 캐시된 nixpkgs 패키지만 사용한다.
8. 이 저장소 스킬·문서는 anki-study의 학습 규칙을 모르고, anki-study의 rules/skills는 이 도구를 모른다.
9. 롤아웃 게이트는 "시크릿 값 투입"이다. `lab`·`main` 두 인스턴스를 함께 배포하되 `main`은
   AnkiWeb 자격 값이 빈 동안 로그인·sync를 하지 않고 조용히 대기한다 (DA R1 운영자 결정).
10. 헬퍼 애드온의 변경 작업(/sync, /export, /import-colpkg)은 상호 배제하고 대기 초과 시 409로 알린다.
    조회는 둘이다 — `/status`는 메인 스레드를 타지 않고 애드온 메모리만 읽어 즉시 답한다(collection_open·login·
    last_sync·busy; 준비 대기·로그인 판정용), `/status/full`은 메인 스레드에서 counts·media까지 채운다(busy면 409).
    `/export`는 새 파일만 만든다(기존 파일 덮어쓰기 거부). `/import-colpkg`는 `allowImport = true` 인스턴스에만 라우팅이
    존재한다(구성 시점 게이트 `ANKI_HOST_ALLOW_IMPORT`, `sync.enable`과 배타 — 모듈 assertion) — 운영 인스턴스에는 없다.
    `/status`는 무인증 응답이라 계정 식별자·덱 이름·카운트를 싣지 않는다. 이 상호 배제는 헬퍼 엔드포인트만 덮는다 —
    같은 프로세스의 AnkiConnect 경유 변경(MCP)은 락 밖이므로 MCP 변경·파괴 도구는 호출 전 `/status`의 `busy`를 확인하고,
    busy면 진행 중 작업 이름과 함께 안내한다(Step 17).
11. 인스턴스 상태 디렉터리의 `backups/`는 일일 백업 스테이징(SSD 최신 2개·HDD 보존 기간). `restore-points/`는
    복구점 자리이며 헬퍼는 이 두 곳에만 쓴다. 복구점의 생산자(MCP 도구)·보존 규칙(미디어 없이 ≈1.5MB, HDD 미러 후
    SSD 최신 N개, HDD 무기한)·미러 코드는 **PR 2b에서 함께** 도입한다 — PR 1에는 디렉터리와 경로 계약만 둔다.
    복원 절차는 Maintenance notes.
12. AnkiWeb 자격은 단일 시크릿이므로 sync를 켠 인스턴스는 최대 1개다(모듈 assertion). sync 계열 도구·
    "지금 동기화"는 `lab`에서 검증하지 않는다(`lab`은 AnkiWeb 미로그인).
13. sync의 운영 계층(상태 파일·알림·결과 분류)은 `anki-host-sync` 스크립트가 단일 소유한다. 헬퍼 `/sync`의
    호출자는 이 스크립트뿐이며, PR 2의 "지금 동기화"는 헬퍼를 직접 부르지 않고 `anki-host-sync-main.service`를
    트리거한다(polkit 규칙으로 MCP 서비스 유저에게 그 유닛의 start만 허용). 요청–결과 대응: 스크립트는 락을 잡은 직후
    `result: running`·`lastAttemptAt`을 먼저 기록하고, 호출자는 트리거 시각을 기억해 `lastAttemptAt`이 그 이후이며
    `result ≠ running`일 때만 그 회차의 결과로 인정한다(폴링). 상태 파일 스키마와 어휘는 `anki-host-sync.sh` 상단 표.
14. 타임아웃 사다리(애드온 락 대기·조회·메인 스레드 < 스크립트 curl < systemd 유닛)와 스크립트의 준비 대기·재시도 상수는
    `constants.ankiHost`가 단일 소스다. 모듈이 env로 스크립트에 주입하고 같은 값으로 유닛 TimeoutStartSec을
    계산하며, 스크립트는 env가 없으면 기본값 없이 실패한다. 애드온 버전도 `default.nix`의 한 바인딩이 nix 파생
    version과 /status를 함께 결정한다.
15. PR 2a 착수 전 결정 항목(#1306 배출 댓글): MCP 서비스 유저와 sync 상태 파일 접근 경로 — 상태 디렉터리는
    0700이므로 `/run` 사본(그룹 읽기) 또는 헬퍼 `/status` 확장 중 하나를 PR 2a Plan DA에서 정한다.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| eval 테스트 | `bash tests/run-eval-tests.sh` | 전부 통과 |
| flake 검사 | `nix flake check` (pre-push가 수행) | 통과 |
| MiniPC 배포 | `ssh minipc` 후 워크트리 체크아웃 → `nrs` | 성공, 실패 유닛 0 |
| Anki 인스턴스 상태 | `ssh minipc 'systemctl status anki-host-lab anki-host-main'` | active |
| AnkiConnect 응답 | `ssh minipc "curl -s -XPOST 127.0.0.1:<port> -d '{\"action\":\"getActiveProfile\",\"version\":6}'"` | 프로필 이름 |
| 헬퍼 상태 | `ssh minipc 'curl -s 127.0.0.1:<helperPort>/status'` (즉시) / `.../status/full` (counts·media) | `collection_open: true`, `login.status` |
| sync 상태 | `ssh minipc 'sudo cat /var/lib/anki-host/main/sync-status.json'` | `result`: `no-credentials` → `bootstrap-pending` → `success` (진행 단계). 나머지 값의 의미는 `anki-host-sync.sh` 상단 어휘 표 |
| 첫 부트스트랩 (🔒 Step 15) | `ssh minipc 'sudo systemctl start anki-host-sync-main-bootstrap && sudo journalctl -u anki-host-sync-main-bootstrap -n 5'` | `full-download` 1회, 알림(b) "처음 내려받았습니다" |
| Funnel 상태 | `ssh minipc 'tailscale funnel status; tailscale serve status'` | 443 funnel → MCP, 8443 serve → 승인 |
| MCP 메타데이터 | `curl -s https://<minipc-ts-name>/.well-known/oauth-protected-resource` | JSON |

유닛 이름 규칙: 인스턴스 `<name>`의 유닛은 `anki-host-<name>`, sync 타이머·서비스는 `anki-host-sync-<name>`,
부트스트랩 oneshot은 `anki-host-sync-<name>-bootstrap`(어떤 target에도 걸리지 않음), 백업은 인스턴스 공통 `anki-host-backup`.
포트 번호는 `libraries/constants.nix`에서 읽는다. 여기에 고정하지 않는다.

## Scope

**포함**: 이슈 #1306 Proposed Changes 전체(PR 1·PR 2).
**제외**: 공개 플러그인 확장 전반, 미디어 URL 방식, import/export 기본 켜기, 오프사이트 백업,
`/var/lib/private/anki-sync-server` 처분, anki-study의 rules/skills/study.py 변경.

## Steps

### PR 1 — headless Anki 복원 + AnkiWeb 동기화 + 알림 + 백업

1. `libraries/constants.nix`에 AnkiConnect·헬퍼 포트(lab/main)와 상태 루트 `paths.ankiHostState` 추가. (MCP·승인 화면 포트는 PR 2 Step 17)
2. `modules/nixos/options/homeserver.nix`에 `ankiHost` 옵션 블록(인스턴스 서브모듈: port·helperPort·sync·backup) + imports. (`ankiMcp` 옵션은 PR 2 Step 19)
3. `modules/nixos/programs/anki-host/default.nix`: 인스턴스별 정적 유닛 `anki-host-<name>`. 과거 default.nix의
   offscreen·`--disable-gpu`·prefs21.db 사전 생성·전용 유저·MemoryMax를 복원하되 값은 조정한다(1G·numBackups 30 —
   근거는 CIR 블록). AnkiConnect `webBindAddress = "127.0.0.1"`, 프로필별 포트, single-instance 키 분리, sync 인스턴스 ≤ 1 assertion.
   `tailscale-wait`는 **복원하지 않는다** — 과거에는 tailnet IP 바인딩 때문에 필요했고, loopback 전용인 지금은 근거가 없다.
4. `anki-host/sync-addon/`: `profile_did_open` 로그인(syncKey 없을 때만, agenix 자격), loopback HTTP
   엔드포인트 `/status`(즉시)·`/status/full`(메인 스레드), `/sync`(mode `normal`·`allow-download-if-empty`만),
   `/export`(새 파일만), `/import-colpkg`(sync 비활성 인스턴스에만 라우팅 — 격리 fixture 전용). 변경 작업 상호 배제 + 409.
   쓰기 경로는 `backups/`·`restore-points/`만 허용. 호출자: `/sync`·`/status`는 `anki-host-sync` 스크립트, `/export`·`/status`는
   백업 스크립트와 PR 2b 복구점 도구, `/import-colpkg`는 Step 12 운영자.
5. `anki-host/sync.nix`: `anki-host-sync-<name>` 서비스 + 15분 타이머(normal), 별도 oneshot `anki-host-sync-<name>-bootstrap`
   (`--mode allow-download-if-empty`, 수동 — 호출자는 Step 15의 운영자뿐), flock, 상태 파일, 결정 3의 방향 정책, Pushover (b)/(c) 알림,
   실패 알림 24h 중복 억제, 빈 컬렉션의 full sync 요구는 `bootstrap-pending`으로 조용히 기록. 스크립트 본문은 pushover 헬퍼와
   헬퍼 호출 공용 함수(`files/lib/helper-call.sh`)를 텍스트 결합해 store에 고정한다.
6. `anki-host/backup.nix`: `backup.enable` 인스턴스만 daily HDD 백업(관례: oneshot+timer, 04:15 — `running-containers` 스킬의
   백업 타이머 표에 등록). `backups/`의 일일 백업본만 다룬다. 준비 대기·busy 재시도는 sync와 같은 공용 함수·상수를 쓴다.
7. `secrets/secrets.nix`: `anki-ankiweb.age`, `pushover-anki.age` 선언(minipcOnly). 저장소에는 빈 값 placeholder를 두고
   🔒 실제 값은 운영자가 재암호화한다.
8. `tests/eval-tests.nix`: loopback 소스 핀, 인스턴스 배선, 타이머 계약, 부트스트랩 유닛 비자동, 백업 대상, `ConditionPathExists`.
9. `bash tests/run-eval-tests.sh` 통과 → 커밋·push.
10. (구현 순서상 Step 14로 이동 — 시크릿 값은 배포 후 투입해도 된다)
11. MiniPC 배포(`ssh minipc` → 워크트리 → `nrs`). `lab`·`main` 두 인스턴스가 함께 뜬다. `main`은 placeholder 시크릿이라
    `login: no-credentials`로 대기하고 sync 타이머는 `no-credentials`로 조용히 종료한다 — 알림 없음이 정상이다.
12. 격리 검증: anki-study 최신 전체 백업 `.colpkg`를 MiniPC로 전송(ssh 파이프, tailnet) → `lab`의 `backups/`에 배치 →
    헬퍼 `/import-colpkg` → 노트·카드·revlog·미디어 수 대조 → `/export`(legacy, 미디어 포함)·백업 서비스 1회 수동 실행 →
    실제 이력 카드 필드 수정 전후 ID·일정·revlog 보존 확인.
13. Plan DA(FULL, Opus 5) → 반영 → 재검증 → PR 1 생성(`create-pr`) → PR DA(FULL, Opus 5) → 머지(`finish-pr`).
14. 🔒 운영자: (a) `anki-ankiweb.age`·`pushover-anki.age`에 실제 값 재암호화(`managing-secrets` 스킬 절차, 값은 저장소·이슈·로그에
    남기지 않는다) → `nrs` → `sudo systemctl restart anki-host-main`(재시작해야 `profile_did_open` 훅이 로그인한다) →
    `/status`의 `login.status`가 `logged-in`(재시작 전에 이미 로그인돼 있었다면 `already-logged-in`). (b) Mac Anki 동기화(AnkiWeb 최신 확인).
    (c) anki-study `docs/recovery.md` 절차로 복구점 등록.
15. 🔒 운영자 명령 1회: `sudo systemctl start anki-host-sync-main-bootstrap`. 결정 3(i) 조건(로컬 노트 0·revlog 0)에서만
    Download가 실행된다. 이후 `/status/full`의 `counts`가 anki-study 최신 백업과 일치할 때만 운영 시작(변경 작업 중이면 409 —
    잠시 후 재시도). Mac 재동기화 후 "변경 없음" 확인.

### PR 2 — MCP 서버 + OAuth + Funnel

16. 🔒 운영자: Tailscale 관리 콘솔 ACL에 MiniPC 노드 `funnel` 속성 허용.
17. PR 2는 두 단계로 나눈다. 용어: **도구 3계층** = 조회(readOnlyHint) / 변경(추가·수정·태그·덱 이동·정지·일정·잊기,
    일정·잊기는 destructiveHint) / 파괴(노트·덱 삭제 — destructiveHint + 확인 인자 + 자동 복구점). **프리셋 공유 경고** =
    덱 옵션 프리셋이 여러 덱에 공유될 때 응답에 그 덱 목록을 붙이는 것(Anki 구조 사실이며 개인 학습 규칙이 아니므로 결정 5와 무관).
    - **PR 2a (최소)**: `libraries/constants.nix`에 MCP·승인 화면 포트. `modules/nixos/programs/anki-mcp/src/` Python 패키지
      (`python3.withPackages`, nixpkgs `mcp`). 조회 계층 + 변경 계층 중 추가·수정·태그, annotations, Anki 검색 문법 통과,
      페이지네이션·필드 절단, `mcp::added` 태그, "지금 동기화"(결정 13 — `anki-host-sync-main.service` 트리거, mode 인자 없음,
      결과는 `sync-status.json`을 결정 13의 running·폴링 규칙으로 읽어 전달). 변경 도구는 호출 전 헬퍼 `/status`의 `busy`를
      확인하고 busy면 진행 중 작업 이름과 함께 안내한다(결정 10 — 재시도는 사용자 몫). Step 18~22와 함께 배포·검증한다.
    - **PR 2b (관측 후)**: 착수 조건은 2a를 실제로 며칠 쓴 뒤의 관측(어떤 도구를 실제로 썼는지, 어떤 마찰이 있었는지).
      파괴 계층, 변경 계층의 정지·일정·잊기, 대량 변경 미리보기/임계값(20건)·자동 복구점(헬퍼 `/export` → `restore-points/`,
      `include_media: false`), base64 미디어(크기 상한), 감사 로그(카드 본문 최소화), 프리셋 공유 경고, full sync 유발 도구
      (결정 3의 Upload 게이트 설계가 선행 조건).
18. 내장 OAuth 2.1 AS(mcp SDK provider): PRM·AS metadata·DCR·PKCE S256·승인 화면(비밀 문구)·
    토큰 만료/갱신/철회·매 요청 검증. TokenVerifier 경계.
19. `homeserver.nix`에 `ankiMcp` 옵션. `anki-mcp/default.nix`: systemd 서비스(loopback), `tailscale.nix`에 Funnel 443→MCP, serve 8443→승인.
    착수 전 결정(결정 15): MCP 서비스 유저(`anki-mcp`, `anki-host` 그룹?)와 sync 상태 파일 접근 경로.
20. `secrets/secrets.nix`: `anki-mcp-oauth.age`. 🔒 값 생성.
21. eval 테스트(Funnel 대상 고정, 승인 포트 funnel 미허용, loopback) + 오프라인 단위 테스트.
22. 배포 → 메타데이터·승인·토큰 흐름을 curl로 검증 → ChatGPT 개발자 모드 플러그인 등록(기존 시험 등록 제거)
    → 🔒 iPhone ChatGPT Chat에서 연결·조회·카드 추가·readback → Codex·Claude 연결·조회 1회. 도구 검증은 `lab`(조회·추가·
    수정·복구점)과 `main`(sync 계열 — 결정 12)으로 나눈다.
23. 실패 경로 검증(인증 실패·만료·철회, AnkiWeb 접속 실패, full sync 요구 중단·알림).
24. `.claude/skills/hosting-anki/` 신규(백업 타이머 표로의 교차 참조 포함). **`lab` 폐기 체크리스트** — PR 2b 검증(파괴 계층·
    대량 변경 미리보기·복구점 — Test plan의 격리 프로필 항목)이 끝나거나 PR 2b 착수를 포기하기로 결정한 뒤에 수행한다.
    PR 2a 직후에 지우면 파괴 도구의 첫 실행 대상이 운영 컬렉션이 된다:
    (a) `configuration.nix`의 `lab` 블록 제거, `constants.nix`의 `ankiConnectLab`·`ankiHelperLab` 제거, eval 테스트의 lab 참조
    정리 → 커밋·배포 (b) `systemctl status anki-host-lab`이 유닛 부재를 보이는지 확인 (c) `/var/lib/anki-host/lab` 상태 루트
    **전체**(Anki2 프로필·`backups/`의 fixture·`restore-points/`·Anki 자체 자동 백업)를 삭제하고 `du`로 실측 확인. 남기지 않는다 —    실제 학습 이력 사본이며 원본은 anki-study 백업에 있다. #863이 남긴 `/var/lib/private/anki-sync-server` 잔재를 반복하지 않는다.
    (d) import를 허용하는 인스턴스가 0이 되므로 애드온의 `/import-colpkg` 구현 제거를 같은 커밋에서 검토한다.
    Plan DA → PR 2 → PR DA → 머지.
25. `plans/README.md` 030 DONE, anki-study #3 완료 검증 체크리스트 갱신.

## Test plan

- 오프라인: `bash tests/run-eval-tests.sh`, `tests/`의 MCP 단위 테스트(도구 계약·annotations·임계값·OAuth 흐름·sync 판정).
- 격리 프로필(실제 이력 fixture): 수정 후 카드 ID·일정·revlog 보존, 복구점 생성, 대량 변경 미리보기, 태그 부착.
- 운영 프로필: 부트스트랩 후 카운트 대조, 타이머 sync 후 알림 (b) 수신, 쓰기 후 알림 (a) 수신, Mac에서 카드 확인.
- 클라이언트: ChatGPT(iPhone) 실제 호출·readback, Codex·Claude 연결·조회.
- 실패 경로: 위 Step 23.

## Done criteria

- PR 1·PR 2 머지, MiniPC `nrs` 적용, `anki-host-main`·`anki-mcp` active, 타이머 정상.
- 운영 프로필 카운트가 Mac 최신 백업과 일치하고, Mac·iPhone 동기화가 정상(변경 없음 또는 정상 병합).
- iPhone ChatGPT Chat에서 카드 추가 → Pushover (a) 알림 → 폰 AnkiMobile 동기화로 카드 확인.
- 이슈 #1306 체크리스트 전부 체크, `plans/README.md` DONE, anki-study #3 완료 검증 갱신.

## STOP conditions

1. `anki-host-main`의 부트스트랩(Step 15)에서 로컬이 비어 있지 않은데 full sync가 요구된다 — 좀비 잠금·잔재 가능성. 방향 결정 금지.
2. 서버 컬렉션 카운트가 anki-study 최신 백업과 다르다(노트·revlog 감소) — Download 전 원인 확인.
3. Mac에서 재동기화 시 "업로드/다운로드 선택" 다이얼로그가 뜬다 — 운영자 보고, 자동 선택 금지.
4. AnkiWeb 로그인 실패 3회 — 자격 재확인, 계정 잠금 방지.
5. eval 게이트(loopback·`allowedTCPPorts`·Funnel 대상)를 통과시키려고 테스트를 완화해야 한다 — 설계 재검토.
6. 승인 화면이 tailnet 밖에서 열린다(Funnel로 8443이 노출) — 즉시 Funnel 해제.
7. 시크릿 값이 로그·이슈·PR·stdout에 나타났다 — 즉시 rotate.
8. 운영자가 시크릿 값 투입·Mac 동기화·ACL 변경을 아직 하지 않았다 — 해당 Step 대기. 특히 자격 투입 전에
   부트스트랩 유닛을 실행하지 않는다. 헬퍼 `/sync`는 `anki-host-sync` 스크립트 외의 호출자를 두지 않는다(결정 13).

## 재개 절차 (다른 기기·새 세션)

1. `gh issue view 1306 --repo greenheadHQ/nixos-config --comments`로 최신 진행 댓글을 읽는다.
2. `git fetch origin feat/anki-mcp-host` 후 `wt feat/anki-mcp-host --if-exists=reuse`로 워크트리 진입.
3. 이 plan의 Drift check와 Status를 확인한다. Status의 Execution·DA 행이 최신 진행 상태다.
4. MiniPC 실측: "Commands you will need"의 인스턴스 상태·헬퍼 상태·sync 상태 세 명령으로 어느 Step까지 적용됐는지 판정한다
   (`no-credentials` = Step 14 전, `bootstrap-pending` = Step 15 전, `success` = 운영 중). 이 세 값 외의 `result`
   (`busy-deferred`·`helper-unreachable`·`login-failed`·`full-sync-required`·`error`)는 운영 중 일시 상태이며 의미와 후속 조치는
   `anki-host-sync.sh` 상단 어휘 표를 따른다 — 다음 타이머 실행 후 재판정한다. 배포되지 않은 코드는
   `git log origin/main..feat/anki-mcp-host`로 본다.
5. 🔒 운영자 게이트가 완료됐는지는 실측으로만 판단한다(`/status`의 `login.status`, Funnel capability `tailscale funnel status`).
6. 진행 상태를 바꾸는 작업을 끝낼 때마다 이슈 #1306에 한 줄 댓글(완료 Step 번호·커밋 SHA·다음 Step)을 남기고 push한다.

## Maintenance notes

- 과거 troubleshooting(`git show 61dadbe1^:.claude/skills/hosting-anki/references/troubleshooting.md`):
  첫 부팅 언어 다이얼로그 블로킹(prefs21.db 사전 생성으로 해결), EGL abort(`--disable-gpu`),
  좀비 잠금 → 빈 컬렉션 시작(`.lock`/`-wal`/`-shm` 정리), OOM(MemoryMax), overlay 캐시 미스.
  이번 실측 추가: aqt가 `sys.stderr`를 오류 다이얼로그 버퍼로 바꾸므로 애드온 로그는 `sys.__stderr__`로 써야 journald에 남는다;
  backend `import_collection_package`는 `col.close()` 후에만 동작한다(`close_for_full_sync`로는 CollectionAlreadyOpen).
- 복구점(.colpkg)은 `<state>/restore-points/`에 둔다. 미러·보존은 PR 2b에서 생산자와 함께 도입한다(결정 11).
  일일 백업본(`backups/`)은 SSD 최신 2개·HDD 보존 기간으로 정리한다.
- **복구점 복원 절차** (운영 인스턴스 `main`): 헬퍼에는 서버를 덮어쓰는 모드가 없으므로 복원은 GUI 경로로 한다 —
  (1) `systemctl stop anki-host-main` (2) Mac Anki에서 격리 프로필을 만들어 복구점 `.colpkg`를 가져와 내용을 확인
  (anki-study `docs/recovery.md`의 복원 원칙과 같다) (3) 확인 후 실제 프로필에 가져오기(전체 컬렉션 교체) → AnkiWeb에
  **Upload** 선택 (4) MiniPC `main`의 프로필 디렉터리(`/var/lib/anki-host/main/Anki2/main/` — 프로필 이름은 인스턴스 이름과 같다)를
  지우고 서비스 시작 →
  `anki-host-sync-main-bootstrap` 재실행(Download). 미디어는 불변이라 일일 백업본의 미디어로 보완한다.
- `homeserver.ankiHost`를 통째로 끄는 날의 처분 계약: 상태 루트 `/var/lib/anki-host` 전체와 HDD `backups/anki-host`의 보존
  여부를 결정해 기록하고, `anki-host` 시스템 계정(`userdel`)까지 정리한다. NixOS는 선언이 사라져도 기존 데이터·계정을
  지우지 않는다 — #863의 미완 정리를 반복하지 않는다.
- 공개 확장 결정 시 입구를 Cloudflare Tunnel + 자체 도메인으로 바꾸면 issuer URL이 바뀌어 클라이언트 재연결 1회가 필요하다.
