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
- **Execution**: IN PROGRESS
- **Plan DA**: PENDING (FULL, Opus 5 전용 — 운영자 지시: Codex quota 없음)
- **PR DA**: PENDING (PR 1·PR 2 각각 FULL, Opus 5 전용)

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
  203MB 잔재(plan 026 Part C STOP, 건드리지 않음).
- Mac: Anki 26.05, AnkiConnect loopback 8765, 프로필 `greenheadHQ`, AnkiWeb 동기화 이행 완료.
- 핀된 nixpkgs: `anki` 25.09.4(withAddons), `ankiAddons.anki-connect`, `python3Packages.mcp` 1.27.1.
  Anki 25.09.4↔26.05는 sync 프로토콜 11·스키마 18 동일.
- 과거 구현: `git show 61dadbe1^:modules/nixos/programs/anki-connect/{default,sync}.nix`,
  `git show 61dadbe1^:.claude/skills/hosting-anki/references/troubleshooting.md`.
- 개인 저장소 PoC: anki-study `experiments/anki-plugin-lab/`(FastMCP, NoAuth, 합성 데이터) —
  도구 계약·멱등·승인 UI 관측의 근거. 코드는 재작성한다.

## Decisions

결정 14건의 정본은 이슈 #1306 "결정" 표다. 구현에 직접 걸리는 불변식만 여기에 둔다.

1. AnkiConnect는 loopback 전용, API 키 없음(Nix store bake 시 평문 노출). MCP 서버만 접근.
2. sync는 애드온이 `col.sync_collection`을 직접 호출한다. AnkiConnect `sync` 액션(GUI 다이얼로그)은 쓰지 않는다.
3. full sync 방향 자동 결정은 두 경우만: (i) 로컬 비어 있음 + 서버 존재 → Download,
   (ii) 운영자가 동의한 도구 실행 직후 + 사전 검사 통과 → Upload. 그 외는 중단·알림.
4. 알림 본문에 카드 내용·자격·토큰을 넣지 않는다. 한국어.
5. 서버 코드에 개인 학습 규칙(덱 이름·태그·배치 규칙)을 넣지 않는다. 범용 도구.
6. Funnel은 MCP 포트(443)만. 승인 화면은 8443 serve(tailnet 전용). 인바운드 방화벽 포트는 열지 않는다.
7. overlay 없이 캐시된 nixpkgs 패키지만 사용한다.
8. 이 저장소 스킬·문서는 anki-study의 학습 규칙을 모르고, anki-study의 rules/skills는 이 도구를 모른다.

## Commands you will need

| Purpose | Command | Expected |
|---------|---------|----------|
| eval 테스트 | `bash tests/run-eval-tests.sh` | 전부 통과 |
| flake 검사 | `nix flake check` (pre-push가 수행) | 통과 |
| MiniPC 배포 | `ssh minipc` 후 워크트리 체크아웃 → `nrs` | 성공, 실패 유닛 0 |
| Anki 인스턴스 상태 | `ssh minipc 'systemctl status anki-host@lab anki-host@main'` | active |
| AnkiConnect 응답 | `ssh minipc "curl -s -XPOST 127.0.0.1:<port> -d '{\"action\":\"getActiveProfile\",\"version\":6}'"` | 프로필 이름 |
| sync 상태 | `ssh minipc 'cat /var/lib/anki-host/main/sync-status.json'` | lastSuccessAt·result |
| Funnel 상태 | `ssh minipc 'tailscale funnel status; tailscale serve status'` | 443 funnel → MCP, 8443 serve → 승인 |
| MCP 메타데이터 | `curl -s https://<minipc-ts-name>/.well-known/oauth-protected-resource` | JSON |

포트 번호는 `libraries/constants.nix`에서 읽는다. 여기에 고정하지 않는다.

## Scope

**포함**: 이슈 #1306 Proposed Changes 전체(PR 1·PR 2).
**제외**: 공개 플러그인 확장 전반, 미디어 URL 방식, import/export 기본 켜기, 오프사이트 백업,
`/var/lib/private/anki-sync-server` 처분, anki-study의 rules/skills/study.py 변경.

## Steps

### PR 1 — headless Anki 복원 + AnkiWeb 동기화 + 알림 + 백업

1. `libraries/constants.nix`에 포트 추가(AnkiConnect lab/main, sync 애드온 엔드포인트, MCP, 승인 화면).
2. `modules/nixos/options/homeserver.nix`에 `ankiHost`·`ankiMcp` 옵션 블록 + imports.
3. `modules/nixos/programs/anki-host/default.nix`: 템플릿 인스턴스 `anki-host@<profile>`.
   과거 default.nix의 offscreen·`--disable-gpu`·prefs21.db 사전 생성·전용 유저·MemoryMax·tailscale-wait를
   복원하고, AnkiConnect `webBindAddress = "127.0.0.1"`, 프로필별 포트. CIR 블록 포함.
4. `anki-host/sync-addon/`: `profile_did_open` 로그인(syncKey 없을 때만, agenix 자격), loopback HTTP
   엔드포인트(`/sync`, `/status`, `/counts`, `/export`)로 sync 실행·결과 코드·전후 카운트·복구점 생성 제공.
5. `anki-host/sync.nix`: `anki-host-sync@<profile>` 서비스 + 15분 타이머, flock, 상태 파일,
   결정 3의 방향 정책, Pushover (b)/(c) 알림(`modules/shared/scripts/lib/pushover.sh`), 실패 중복 억제.
6. `anki-host/backup.nix`: daily HDD 백업(관례: oneshot+timer, 04:30/05:00/05:30과 겹치지 않는 시각).
7. `secrets/secrets.nix`: `anki-ankiweb.age`, `pushover-anki.age` 선언(minipcOnly). 🔒 값은 운영자가 생성.
8. `tests/eval-tests.nix`: loopback 강제, 인스턴스 배선, 타이머 계약, `ConditionPathExists`.
9. `bash tests/run-eval-tests.sh` 통과 → 커밋·push.
10. 🔒 운영자: agenix 시크릿 2개 생성(`managing-secrets` 스킬 절차). 값은 저장소·이슈·로그에 남기지 않는다.
11. MiniPC 배포(`ssh minipc` → 워크트리 → `nrs`). `anki-host@lab`만 enable한 상태로 시작.
12. 격리 검증: anki-study 최신 전체 백업 `.colpkg`를 MiniPC로 전송(scp, tailnet) → `lab` 프로필에
    import(애드온 엔드포인트 또는 AnkiConnect `importPackage`) → 노트·카드·revlog 수 대조 →
    `/counts`·`/export` 동작 → 백업 타이머 1회 수동 실행.
13. Plan DA(FULL, Opus 5) → PR 1 생성(`create-pr`) → PR DA(FULL, Opus 5) → 머지(`finish-pr`).
14. 🔒 운영자: Mac Anki 동기화(AnkiWeb 최신 확인). anki-study `docs/recovery.md` 절차로 복구점 등록.
15. `anki-host@main` enable → 배포 → 애드온 로그인 → 첫 sync. 결정 3(i) 조건에서만 Download.
    카운트가 anki-study 최신 백업과 일치할 때만 운영 시작. Mac 재동기화 후 "변경 없음" 확인.

### PR 2 — MCP 서버 + OAuth + Funnel

16. 🔒 운영자: Tailscale 관리 콘솔 ACL에 MiniPC 노드 `funnel` 속성 허용.
17. `modules/nixos/programs/anki-mcp/src/`: Python 패키지(`python3.withPackages`, nixpkgs `mcp`).
    도구 3계층·annotations·Anki 검색 문법·페이지네이션·필드 절단·`mcp::added`·full sync 고지/확인 인자·
    대량 변경 미리보기/임계값·프리셋 공유 경고·base64 미디어·복구점·감사 로그·"지금 동기화".
18. 내장 OAuth 2.1 AS(mcp SDK provider): PRM·AS metadata·DCR·PKCE S256·승인 화면(비밀 문구)·
    토큰 만료/갱신/철회·매 요청 검증. TokenVerifier 경계.
19. `anki-mcp/default.nix`: systemd 서비스(loopback), `tailscale.nix`에 Funnel 443→MCP, serve 8443→승인.
20. `secrets/secrets.nix`: `anki-mcp-oauth.age`. 🔒 값 생성.
21. eval 테스트(Funnel 대상 고정, 승인 포트 funnel 미허용, loopback) + 오프라인 단위 테스트.
22. 배포 → 메타데이터·승인·토큰 흐름을 curl로 검증 → ChatGPT 개발자 모드 플러그인 등록(기존 시험 등록 제거)
    → 🔒 iPhone ChatGPT Chat에서 연결·조회·카드 추가·readback → Codex·Claude 연결·조회 1회.
23. 실패 경로 검증(인증 실패·만료·철회, AnkiWeb 접속 실패, full sync 요구 중단·알림).
24. `.claude/skills/hosting-anki/` 신규. Plan DA → PR 2 → PR DA → 머지.
25. `plans/README.md` 030 DONE, anki-study #3 완료 검증 체크리스트 갱신.

## Test plan

- 오프라인: `bash tests/run-eval-tests.sh`, `tests/`의 MCP 단위 테스트(도구 계약·annotations·임계값·OAuth 흐름·sync 판정).
- 격리 프로필(실제 이력 fixture): 수정 후 카드 ID·일정·revlog 보존, 복구점 생성, 대량 변경 미리보기, 태그 부착.
- 운영 프로필: 첫 sync 카운트 대조, 타이머 sync 후 알림 (b) 수신, 쓰기 후 알림 (a) 수신, Mac에서 카드 확인.
- 클라이언트: ChatGPT(iPhone) 실제 호출·readback, Codex·Claude 연결·조회.
- 실패 경로: 위 Step 23.

## Done criteria

- PR 1·PR 2 머지, MiniPC `nrs` 적용, `anki-host@main`·`anki-mcp` active, 타이머 정상.
- 운영 프로필 카운트가 Mac 최신 백업과 일치하고, Mac·iPhone 동기화가 정상(변경 없음 또는 정상 병합).
- iPhone ChatGPT Chat에서 카드 추가 → Pushover (a) 알림 → 폰 AnkiMobile 동기화로 카드 확인.
- 이슈 #1306 체크리스트 전부 체크, `plans/README.md` DONE, anki-study #3 완료 검증 갱신.

## STOP conditions

1. `anki-host@main` 첫 sync에서 로컬이 비어 있지 않은데 full sync가 요구된다 — 좀비 잠금·잔재 가능성. 방향 결정 금지.
2. 서버 컬렉션 카운트가 anki-study 최신 백업과 다르다(노트·revlog 감소) — Download 전 원인 확인.
3. Mac에서 재동기화 시 "업로드/다운로드 선택" 다이얼로그가 뜬다 — 운영자 보고, 자동 선택 금지.
4. AnkiWeb 로그인 실패 3회 — 자격 재확인, 계정 잠금 방지.
5. eval 게이트(loopback·`allowedTCPPorts`·Funnel 대상)를 통과시키려고 테스트를 완화해야 한다 — 설계 재검토.
6. 승인 화면이 tailnet 밖에서 열린다(Funnel로 8443이 노출) — 즉시 Funnel 해제.
7. 시크릿 값이 로그·이슈·PR·stdout에 나타났다 — 즉시 rotate.
8. 운영자가 Mac 동기화·시크릿 생성·ACL 변경을 아직 하지 않았다 — 해당 Step 대기, 우회 금지.

## 재개 절차 (다른 기기·새 세션)

1. `gh issue view 1306 --repo greenheadHQ/nixos-config --comments`로 최신 진행 댓글을 읽는다.
2. `git fetch origin feat/anki-mcp-host` 후 `wt feat/anki-mcp-host --if-exists=reuse`로 워크트리 진입.
3. 이 plan의 Drift check와 Status를 확인한다. Status의 Execution·DA 행이 최신 진행 상태다.
4. MiniPC 실측: "Commands you will need"의 상태 조회 4개를 실행해 어느 Step까지 적용됐는지 판정한다.
   배포되지 않은 코드는 `git log origin/main..feat/anki-mcp-host`로 본다.
5. 🔒 운영자 게이트가 완료됐는지는 실측으로만 판단한다(시크릿 파일 존재 `ssh minipc 'ls /run/agenix/'`,
   Funnel capability `tailscale funnel status`).
6. 진행 상태를 바꾸는 작업을 끝낼 때마다 이슈 #1306에 한 줄 댓글(완료 Step 번호·커밋 SHA·다음 Step)을 남기고 push한다.

## Maintenance notes

- 과거 troubleshooting(`git show 61dadbe1^:.claude/skills/hosting-anki/references/troubleshooting.md`):
  첫 부팅 언어 다이얼로그 블로킹(prefs21.db 사전 생성으로 해결), EGL abort(`--disable-gpu`),
  좀비 잠금 → 빈 컬렉션 시작(`.lock`/`-wal`/`-shm` 정리), OOM(MemoryMax), overlay 캐시 미스.
- 복구점(.colpkg)은 MiniPC 상태 디렉터리에 두고 daily HDD 백업에 포함한다. 자동 삭제하지 않는다.
- 공개 확장 결정 시 입구를 Cloudflare Tunnel + 자체 도메인으로 바꾸면 issuer URL이 바뀌어 클라이언트 재연결 1회가 필요하다.
