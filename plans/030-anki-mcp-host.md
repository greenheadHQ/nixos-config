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
- **Plan DA**: R1 COMPLETE (FULL, Opus 5 — reviewer 4 + Arbiter 1). finding 21건 전부 CONFIRMED, 19건 FIX_NOW + 2건(롤아웃 계약 UNCLEAR)은 운영자 결정 "계획을 구현에 맞춰 갱신"으로 FIX_NOW 편입. 재검증 라운드 대기
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
3. full sync 방향 자동 결정은 두 경우만: (i) 로컬 비어 있음 + 서버 존재 → Download — **운영자가 부트스트랩
   유닛을 명시 실행할 때만** (타이머는 빈 컬렉션의 full sync 요구를 알림 없이 `bootstrap-pending`으로 기록),
   (ii) 운영자가 동의한 도구 실행 직후 + 사전 검사 통과 → Upload. 그 외는 중단·알림.
4. 알림 본문에 카드 내용·자격·토큰을 넣지 않는다. 한국어.
5. 서버 코드에 개인 학습 규칙(덱 이름·태그·배치 규칙)을 넣지 않는다. 범용 도구.
6. Funnel은 MCP 포트(443)만. 승인 화면은 8443 serve(tailnet 전용). 인바운드 방화벽 포트는 열지 않는다.
7. overlay 없이 캐시된 nixpkgs 패키지만 사용한다.
8. 이 저장소 스킬·문서는 anki-study의 학습 규칙을 모르고, anki-study의 rules/skills는 이 도구를 모른다.
9. 롤아웃 게이트는 "시크릿 값 투입"이다. `lab`·`main` 두 인스턴스를 함께 배포하되 `main`은
   AnkiWeb 자격 값이 빈 동안 로그인·sync를 하지 않고 조용히 대기한다 (DA R1 운영자 결정).
10. 헬퍼 애드온의 변경 작업(/sync, /export, /import-colpkg)은 상호 배제하고 대기 초과 시 409로 알린다.
    조회(/status, /counts)는 진행 중 작업이 있어도 busy 표시가 붙은 부분 응답을 즉시 준다.
11. 인스턴스 상태 디렉터리의 `backups/`는 일일 백업 스테이징(정리 대상), `restore-points/`는
    복구점(정리 제외, HDD 미러). 헬퍼는 이 두 곳에만 쓴다.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| eval 테스트 | `bash tests/run-eval-tests.sh` | 전부 통과 |
| flake 검사 | `nix flake check` (pre-push가 수행) | 통과 |
| MiniPC 배포 | `ssh minipc` 후 워크트리 체크아웃 → `nrs` | 성공, 실패 유닛 0 |
| Anki 인스턴스 상태 | `ssh minipc 'systemctl status anki-host-lab anki-host-main'` | active |
| AnkiConnect 응답 | `ssh minipc "curl -s -XPOST 127.0.0.1:<port> -d '{\"action\":\"getActiveProfile\",\"version\":6}'"` | 프로필 이름 |
| 헬퍼 상태 | `ssh minipc 'curl -s 127.0.0.1:<helperPort>/status'` | `collection_open: true`, `login.status` |
| sync 상태 | `ssh minipc 'sudo cat /var/lib/anki-host/main/sync-status.json'` | `result`: `no-credentials` → `bootstrap-pending` → `success` |
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
   offscreen·`--disable-gpu`·prefs21.db 사전 생성·전용 유저·MemoryMax를 복원하고, AnkiConnect `webBindAddress = "127.0.0.1"`,
   프로필별 포트, single-instance 키 분리. CIR 블록 포함. `tailscale-wait`는 **복원하지 않는다** — 과거에는 tailnet IP 바인딩
   때문에 필요했고, loopback 전용인 지금은 근거가 없다.
4. `anki-host/sync-addon/`: `profile_did_open` 로그인(syncKey 없을 때만, agenix 자격), loopback HTTP
   엔드포인트(`/status`, `/counts`, `/sync`, `/export`, `/import-colpkg`)로 sync 실행·결과 코드·전후 카운트·복구점 생성 제공.
   변경 작업 상호 배제 + 409, 조회는 busy 부분 응답. 쓰기 경로는 `backups/`·`restore-points/`만 허용.
5. `anki-host/sync.nix`: `anki-host-sync-<name>` 서비스 + 15분 타이머(normal), 별도 oneshot `anki-host-sync-<name>-bootstrap`
   (`--mode allow-download-if-empty`, 수동), flock, 상태 파일, 결정 3의 방향 정책, Pushover (b)/(c) 알림
   (`modules/shared/scripts/lib/pushover.sh`), 실패 알림 24h 중복 억제, 빈 컬렉션의 full sync 요구는 `bootstrap-pending`으로 조용히 기록.
6. `anki-host/backup.nix`: `backup.enable` 인스턴스만 daily HDD 백업(관례: oneshot+timer, 04:15). `backups/`의 일일 백업본만
   정리하고 `restore-points/`는 HDD로 미러만 한다.
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
    `/status`가 `logged_in: true`. (b) Mac Anki 동기화(AnkiWeb 최신 확인). (c) anki-study `docs/recovery.md` 절차로 복구점 등록.
15. 🔒 운영자 명령 1회: `sudo systemctl start anki-host-sync-main-bootstrap`. 결정 3(i) 조건(로컬 노트 0·revlog 0)에서만
    Download가 실행된다. 이후 `/status` 카운트가 anki-study 최신 백업과 일치할 때만 운영 시작. Mac 재동기화 후 "변경 없음" 확인.

### PR 2 — MCP 서버 + OAuth + Funnel

16. 🔒 운영자: Tailscale 관리 콘솔 ACL에 MiniPC 노드 `funnel` 속성 허용.
17. `libraries/constants.nix`에 MCP·승인 화면 포트 추가. `modules/nixos/programs/anki-mcp/src/`: Python 패키지(`python3.withPackages`,
    nixpkgs `mcp`). 도구 3계층·annotations·Anki 검색 문법·페이지네이션·필드 절단·`mcp::added`·full sync 고지/확인 인자·
    대량 변경 미리보기/임계값·프리셋 공유 경고·base64 미디어·복구점(헬퍼 `/export` → `restore-points/`)·감사 로그·"지금 동기화"
    (헬퍼 `/sync` 호출, 409는 "다른 작업 진행 중"으로 사용자에게 전달).
18. 내장 OAuth 2.1 AS(mcp SDK provider): PRM·AS metadata·DCR·PKCE S256·승인 화면(비밀 문구)·
    토큰 만료/갱신/철회·매 요청 검증. TokenVerifier 경계.
19. `homeserver.nix`에 `ankiMcp` 옵션. `anki-mcp/default.nix`: systemd 서비스(loopback), `tailscale.nix`에 Funnel 443→MCP, serve 8443→승인.
20. `secrets/secrets.nix`: `anki-mcp-oauth.age`. 🔒 값 생성.
21. eval 테스트(Funnel 대상 고정, 승인 포트 funnel 미허용, loopback) + 오프라인 단위 테스트.
22. 배포 → 메타데이터·승인·토큰 흐름을 curl로 검증 → ChatGPT 개발자 모드 플러그인 등록(기존 시험 등록 제거)
    → 🔒 iPhone ChatGPT Chat에서 연결·조회·카드 추가·readback → Codex·Claude 연결·조회 1회.
23. 실패 경로 검증(인증 실패·만료·철회, AnkiWeb 접속 실패, full sync 요구 중단·알림).
24. `.claude/skills/hosting-anki/` 신규. `lab` 인스턴스는 PR 2 도구 검증까지 유지한 뒤 `enable = false`로 내린다
    (검증 사본은 `restore-points/`·anki-study 백업으로 재현 가능). Plan DA → PR 2 → PR DA → 머지.
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
   부트스트랩 유닛을 실행하거나 헬퍼 `/sync`에 `download`/`upload` 모드를 직접 보내지 않는다.

## 재개 절차 (다른 기기·새 세션)

1. `gh issue view 1306 --repo greenheadHQ/nixos-config --comments`로 최신 진행 댓글을 읽는다.
2. `git fetch origin feat/anki-mcp-host` 후 `wt feat/anki-mcp-host --if-exists=reuse`로 워크트리 진입.
3. 이 plan의 Drift check와 Status를 확인한다. Status의 Execution·DA 행이 최신 진행 상태다.
4. MiniPC 실측: "Commands you will need"의 인스턴스 상태·헬퍼 상태·sync 상태 세 명령으로 어느 Step까지 적용됐는지 판정한다
   (`no-credentials` = Step 14 전, `bootstrap-pending` = Step 15 전, `success` = 운영 중). 배포되지 않은 코드는
   `git log origin/main..feat/anki-mcp-host`로 본다.
5. 🔒 운영자 게이트가 완료됐는지는 실측으로만 판단한다(`/status`의 `logged_in`, Funnel capability `tailscale funnel status`).
6. 진행 상태를 바꾸는 작업을 끝낼 때마다 이슈 #1306에 한 줄 댓글(완료 Step 번호·커밋 SHA·다음 Step)을 남기고 push한다.

## Maintenance notes

- 과거 troubleshooting(`git show 61dadbe1^:.claude/skills/hosting-anki/references/troubleshooting.md`):
  첫 부팅 언어 다이얼로그 블로킹(prefs21.db 사전 생성으로 해결), EGL abort(`--disable-gpu`),
  좀비 잠금 → 빈 컬렉션 시작(`.lock`/`-wal`/`-shm` 정리), OOM(MemoryMax), overlay 캐시 미스.
  이번 실측 추가: aqt가 `sys.stderr`를 오류 다이얼로그 버퍼로 바꾸므로 애드온 로그는 `sys.__stderr__`로 써야 journald에 남는다;
  backend `import_collection_package`는 `col.close()` 후에만 동작한다(`close_for_full_sync`로는 CollectionAlreadyOpen).
- 복구점(.colpkg)은 `<state>/restore-points/`에 두며 백업 서비스가 HDD `backups/anki-host/<name>/restore-points/`로
  미러만 하고 어느 쪽에서도 자동 삭제하지 않는다. 일일 백업본(`backups/`)은 SSD 최신 2개·HDD 보존 기간으로 정리한다.
- 공개 확장 결정 시 입구를 Cloudflare Tunnel + 자체 도메인으로 바꾸면 issuer URL이 바뀌어 클라이언트 재연결 1회가 필요하다.
