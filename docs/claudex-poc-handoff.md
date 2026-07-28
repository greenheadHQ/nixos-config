# Claudex PoC 인수인계

## TL;DR

- **상황**: 기존 foreground PoC를 사용자용 단일 명령과 on-demand lifecycle로 확장했다. 세션을 여는 `claudex`가 필요할 때 proxy를 자동 시작하고, `claudex login|status|proxy`가 나머지 작업을 담당한다.
- **현재 상태**: 두 Darwin 호스트와 NixOS 호스트(`greenhead-minipc`)를 허용하는 descriptor schema 3, private traffic gate, launchd/systemd-user 실패 복구, graceful drain, credential 손상 복구가 구현됐다.
- **다음 액션**: 정적·fixture 검증 후 승인된 호스트에서 `nrs`와 실제 session/stop/refresh 관측을 수행한다.
- **Blockers**: 코드 blocker는 없다. 실제 OAuth, refresh, process/network 관측은 실행 직전 사용자 승인이 필요하다.

> **대상**: `modules/shared/programs/claudex/`와 Darwin Home Manager 연결부
> **목표**: 새 머신에서 실제 device OAuth → on-demand managed proxy → `claudex` completion을 재현하고, 필요하면 foreground 진단 경로도 사용할 수 있게 한다.
> **예상 소요**: 30~60분
> **난이도**: 복잡

이 문서는 이전 대화 없이 단독으로 실행할 수 있는 재개 지침이다. 기억이나 이전 터미널 출력보다 현재 브랜치, 파일시스템, CLI 실측을 우선한다.

## 1. 최종 목표와 범위

`claudex`는 기존 `claude` 설정을 수정하지 않고, 별도 wrapper 경계 안에서만 다음 경로를 강제한다.

```text
Claude Code
  -> ANTHROPIC_BASE_URL=http://127.0.0.1:8317
  -> claudex traffic gate (public bearer 검증·drain)
  -> private TLS backend
  -> pinned CLIProxyAPI child
  -> Codex device OAuth credential
  -> gpt-5.6-sol
```

기본 경로는 `claudex` 첫 세션에서 managed proxy를 자동 시작한다. 로그인 시 무조건 띄우지는 않으며, 사용하지 않는 머신에는 상주 process가 없다. 다음은 범위 밖이다.

- upstream CLIProxyAPI source patch/build
- provider별 별도 proxy 또는 별도 auth-dir
- 원격 caller를 새 trust boundary로 추가하는 기능
- 일반 `claude` 명령이나 기존 Claude settings 변경

fake 테스트만으로는 upstream 바이너리의 실제 설정 파싱, 계정 entitlement, OAuth credential 생성·refresh, Claude Code의 provider 호환성을 증명할 수 없다. 그래서 실제 completion이 최종 성공 기준이다.

## 2. Git 기준선

이 문서는 특정 작업 브랜치나 commit ID를 기준선으로 고정하지 않는다. Stage 1의
`codex/claudex-poc` 브랜치와 당시 merge base는 역사적 구현 기록이며 현재 재개 지점이 아니다.
새 세션에서는 작업 중인 PR/branch와 최신 `origin/main`을 직접 확인한다.

```bash
git fetch origin main
git status --short --branch
git log --oneline --decorate -5
git merge-base HEAD origin/main
```

PR을 이어받는 경우에는 GitHub의 현재 head branch와 commit을 먼저 확인하고 그 branch의 기존
worktree를 사용한다. 이 문서만 보고 별도 Stage 1 branch를 만들거나 force-push하지 않는다.

커밋 전에는 개인 식별자, 조직·고객 식별자, 로컬 사용자명이 포함된 절대 경로, 내부 분류 문구가 staged diff와 커밋 메시지에 없는지 대소문자 무시로 검사한다. 런타임 credential, API key, 브라우저 계정 정보는 어떤 형태로도 커밋하지 않는다.

## 3. 구현 지도

### 선언과 패키지

- `modules/darwin/home.nix`
  - Darwin Home Manager에 `../shared/programs/claudex`를 import한다.
- `modules/shared/programs/claudex/default.nix`
  - 호스트 enable gate, state 경로, loopback 주소, 포트, 모델, runtime package, descriptor를 선언한다.
  - 모듈을 import한 모든 호스트(darwin·nixos)에는 대상 여부와 무관하게 descriptor와 runtime library가 생긴다.
  - enable된 호스트에는 public 명령 `claudex` 하나와 private proxy launcher만 노출한다. 옛 `claudex-login`·`claudex-status` public shim은 설치하지 않는다.
  - Darwin은 on-demand private launchd plist, Linux는 `WantedBy` 없는 systemd user service를 사용한다. 둘 다 실패할 때만 재시작하며 login/activation 때 자동 시작하지 않는다.
- `modules/shared/programs/claudex/package.nix`
  - CLIProxyAPI prebuilt archive를 고정하고 release layout을 검증한 뒤 바이너리 하나만 설치한다.
- `modules/shared/programs/claudex/cli-proxy-api-pin.json`
  - 버전 `7.2.73`과 플랫폼별 asset(darwin arm64 / linux amd64) SRI를 고정한다. linux prebuilt는 glibc 동적 링크에 FHS interpreter를 달고 오므로 `autoPatchelfHook`으로 interpreter를 nix store로 재작성해야 실행되고, darwin은 Mach-O 서명 보존을 위해 `dontPatchELF`를 유지한다 (의도된 플랫폼 비대칭이며 eval 테스트가 잠근다).
- `modules/shared/programs/claudex/files/verify-release-layout.sh`
  - archive 최상위 5개 항목의 이름과 type을 정확히 검증한다.

### 런타임

- `modules/shared/programs/claudex/files/claudex-runtime.sh`
  - state 생성, 권한 검증, config 렌더링, credential 검증, loopback curl, state/lifecycle lock을 담당한다.
  - 동일한 config 재렌더링은 기존 파일 inode를 보존하고, 실제 내용 변경만 원자적으로 교체한다.
  - bind host에서 `NO_PROXY` 값을 파생해 wrapper, login, launcher, loopback curl이 같은 계약을 사용한다.
  - production variant는 home/state/tool/template 경로를 Nix 치환값으로 고정하고 환경 변수 override를 받지 않는다.
- `modules/shared/programs/claudex/files/claudex-login.sh`
  - device OAuth를 임시 staging 디렉터리에서 수행한다.
  - 정확히 하나의 유효 credential만 canonical auth 디렉터리로 원자적으로 승격한다.
  - 중단·실패 시 staging을 정리한다.
- `modules/shared/programs/claudex/files/claudex-proxy.sh`
  - `start`, `stop`, `restart`, `foreground`, `logs`를 제공한다.
  - generation이 바뀐 managed proxy는 active request를 drain한 뒤 교체하고, 사용 중이면 현재 process를 유지해 다음 세션으로 갱신을 미룬다.
- `modules/shared/programs/claudex/files/claudex-proxy-launcher.sh`
  - private state와 credential을 검증하고 traffic gate를 managed 또는 foreground mode로 실행한다.
- `modules/shared/programs/claudex/gate/`
  - `127.0.0.1:8317` public bearer를 검증하고, 임시 key와 per-instance TLS를 쓰는 `127.0.0.1:8318` backend child로 요청을 전달한다.
  - active request 수를 handler lifetime 동안 추적해 새 요청을 막고 drain한 뒤 child를 종료한다.
  - 시작 시 schema-valid credential set을 snapshot하고, 종료 뒤 canonical JSON이 empty/partial/invalid면 검증된 snapshot으로 복구·재검증한다.
  - 복구는 같은 filesystem의 두 directory rename을 사용한다. 두 rename 사이에 process가 강제 종료되면 canonical path가 잠시 없을 수 있으므로 남은 `.auth-invalid-*`와 instance snapshot을 보존하고 operator 확인을 요구한다.
- `modules/shared/programs/claudex/files/claudex.sh`
  - 첫 인자를 기준으로 `login`, `status`, `proxy`, `help`를 routing하고, 그 외 인자는 기존 Claude session argv로 처리한다.
  - session 전에 managed proxy를 자동으로 준비한다.
  - provider/model/settings 관련 사용자 override를 거부한다.
  - `CLAUDE_CODE_EXTRA_BODY`, inherited `CLAUDE_CODE_EFFORT_LEVEL`, `ANTHROPIC_UNIX_SOCKET`, Claude host-auth bridge 환경을 포함한 endpoint/request/transport override 환경을 scrub한다.
  - wrapper-owned settings 파일로 `CLAUDE_CODE_EXTRA_BODY`를 고정해 user/project settings의 request-body override를 중화한다. variant는 두 개이며 모두 pinned Nix store 파일이다 — 기본 variant는 `{}`, fast variant는 `{"service_tier":"priority"}`.
  - 빈 CLI fallback 목록으로 settings의 `fallbackModel`을 마스킹하고, wrapper-owned `CLAUDE_CODE_EFFORT_LEVEL`을 다시 설정한다.
  - loopback catalog에서 세션의 main model(및 mixed에서는 subagent model까지)을 확인한 뒤 `$HOME/.local/bin/claude`를 실행한다.
  - model 계약은 역할별로 고정한다: default 모드 main = `gpt-5.6-sol`, 모든 모드의 subagent(`CLAUDE_CODE_SUBAGENT_MODEL`) = `gpt-5.6-sol`, `--mixed` 모드 main = `claude-opus-4-8`. 사용자 `--model` override는 여전히 거부된다. 이 고정은 **세션 시작값**이다 — 세션 중 `/model` 전환(CLI 기능)으로 카탈로그의 다른 모델로 바꿀 수 있음이 실측됐다(2026-07-17). 구독 플랜의 모델 정책 변화 시 pin 재조정은 #1130이 추적한다. effort는 기본 `high`이며, 명시적 `claudex --effort <low|medium|high|xhigh|max|ultra>` 인자만 세션 값을 바꾼다. `ultra`는 pinned CLI가 argv에서 warn-then-ignore하므로 env 값으로만 전달한다.
  - `--mixed`(불리언; `--mixed=<값>` 거부)는 혼합 fleet 세션을 연다: main은 proxy의 claude credential로 서빙되는 Claude 모델, 서브에이전트는 그대로 gpt. mixed는 canonical auth에 codex+claude credential이 모두 있어야 시작되고(`claudex login claude`로 추가), `--mixed --fast` 조합은 fail-closed로 거부된다(fast 티어는 Codex 백엔드 전용 request-body knob).
  - Codex fast 티어는 불리언 `claudex --fast` 인자만 켠다(`--fast=<값>`은 거부). wrapper가 fast settings variant를 선택해 request body에 `service_tier`를 주입하며, 값은 온-와이어 canonical id인 `"priority"`(카탈로그 id `priority`, 표시명 "Fast")를 사용해 proxy 변환기의 `"fast"` 별칭 매핑에 의존하지 않는다. Claude CLI에는 대응 argv가 없으므로(자체 fastMode는 Anthropic 직접 API 전용 별개 기능) argv 재발행은 없다.
  - `--dangerously-skip-permissions`로 실행해 세션이 항상 bypassPermissions로 시작한다 (pinned CLI는 시작 플래그 없이 세션 중 bypass 전환이 불가능). 이 계약이 조용히 뒤집히지 않도록 사용자 인자의 `--permission-mode`도 wrapper-owned 옵션으로 거부한다.
  - context window를 wrapper-owned `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000`으로 고정하고, 같은 값을 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`로도 재발행한다 (후자가 없으면 미인식 모델에서 compact window source가 "auto"로 남아 pinned CLI가 auto-compact를 로컬 세션 가드로 비활성화한다 — 2.1.210 실측). 두 상속 환경값 모두 scrub된다. `272000`은 공식 Codex catalog의 raw `context_window`이며, Codex가 별도의 95% headroom을 적용해 표시하는 `258400` effective window와 구분한다. Claude Code는 선언된 window 아래에서 자체 output/compact headroom을 적용하므로 effective 값을 다시 넣지 않는다 — 아래 "context 사용률 표시는 근사치" 항목과 #1113 참조. 예외: `--mixed`에서는 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`를 재발행하지 않는다 — 이 env에는 모델 스코프가 없어 인식 모델인 Claude main의 compact 임계까지 끌어내리기 때문이며, 대가로 mixed의 gpt 서브에이전트는 auto-compact 없이 돈다(서브 작업이 window를 크게 밑돈다는 가정, 이슈 #1127). `CLAUDE_CODE_MAX_CONTEXT_TOKENS`는 비-claude 모델 전용이라 양쪽 모드에서 유지된다. 이 설정은 시작 모드 기준이다. 세션 중 `/model`로 default→Claude 전환하면 전역 AUTO 값이 남아 Claude native window보다 이르게 compact하고, mixed→GPT 전환하면 AUTO가 없어 auto-compact가 비활성인 기존 한계가 있다.
- `modules/shared/programs/claudex/files/claudex-status.sh`
  - `claudex status`는 사람이 읽는 한국어 요약, `claudex status --json`은 stable English key를 출력한다.
  - auth readiness는 local schema/file 검사이고 `auth_live_validity=unchecked`를 별도로 표시한다. proxy 상태와 합쳐서 “로그인됨”으로 단정하지 않는다.
- `modules/shared/programs/claudex/files/config-template.json`
  - runtime-owned host/port/pprof slot은 비워 두고, remote management·plugin·파일 로그·통계 비활성화를 선언한다.
  - `default.nix`의 단일 runtime contract가 최종 `127.0.0.1:8317`, 모델, label, pprof 주소를 runtime과 config에 함께 주입한다.
  - 세션 불안정(520→429 cooldown 연쇄) 완화용 resilience knob 4종을 선언한다: `max-retry-interval: 30`(cooldown 흡수 활성화 — code default 0이면 완전 비활성), `passthrough-headers: true`(Retry-After 전달), `transient-error-cooldown-seconds: -1`(5xx 부수 벤치 제거), `streaming.{keepalive-seconds: 15, bootstrap-retries: 1}`(520 first-byte 재시도 + idle timeout 방지). 근거는 `default.nix`의 CIR 주석과 §4 참조. 이 값들도 runtime.sh의 config key 화이트리스트가 정확히 검증하므로 값 변경 시 두 곳을 함께 갱신한다.

### 검증 연결

- `tests/suites/claudex.sh`: unified CLI, fake boundary, state mode, credential shape, wrapper scrub, wrapper-owned settings, lifecycle runtime 계약, 실제 Nix-generated command output, layout drift, synthetic disabled Home Manager closure를 검증한다. fixture materialization 뒤 미치환 placeholder가 하나라도 남으면 실패한다.
- `tests/shell-script-tests.sh`: 위 suite를 전체 shell suite에 등록한다.
- `tests/eval-tests.nix`: descriptor schema 3, 실제·synthetic host 노출, pin, config, no-login-autostart, systemd/launchd lifecycle과 portable Nix derivation 계약을 평가한다. 실제 command output 내용은 shell test가 build/read한다.
- `lefthook.yml`과 `scripts/ai/check-lefthook-staged-config.sh`: JSON pin/template 변경이 eval 검증을 타도록 한다.

## 4. 고정 계약

| 항목 | 값 |
|---|---|
| Proxy | CLIProxyAPI `7.2.73` — darwin arm64 / linux amd64 (플랫폼별 asset·SRI pin) |
| Bind | `127.0.0.1:8317` |
| 모델 (default main / subagent) | `gpt-5.6-sol` / `gpt-5.6-sol` |
| 모델 (mixed main) | `claude-opus-4-8` (`claudex --mixed`; descriptor `.model`은 default main alias; 재조정 트리거 #1130) |
| Runtime state | darwin: `$HOME/Library/Application Support/claudex` · linux: `$HOME/.local/state/claudex` (XDG) |
| Descriptor | `$HOME/.config/claudex/runtime.json`, schema `3` |
| Enabled hosts | `greenhead-MacBookPro`, `work-MacBookPro`, `greenhead-minipc` |
| Claude 실행 파일 | `$HOME/.local/bin/claude` |
| Service label | `org.nix-community.home.claudex-proxy` |
| Context window override | `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000` + `CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000` (wrapper-owned; Codex raw catalog window 추종, 단일 상수 공유). mixed에서는 AUTO_COMPACT_WINDOW 미발행 |
| Lifecycle | 첫 `claudex` session에서 on-demand 시작; Darwin private launchd / Linux systemd-user, failure-only restart, login autostart 없음 |
| Public CLI | `claudex`, `claudex login`, `claudex status`, `claudex proxy`, `claudex help` |
| 상태 잠금 | state lock과 lifecycle lock을 분리한 `flock` fd 모드(`-x -w`) — darwin은 nixpkgs `flock`(discoteq), linux는 `util-linux` |

보안·정합성 불변식:

1. listener는 loopback만 사용한다.
2. client API key는 state 디렉터리의 mode `0600` 파일이며, 정확히 64자의 lowercase hex여야 한다.
3. state/auth/runtime 디렉터리는 symlink가 아니어야 하고 private mode를 유지해야 한다.
4. canonical auth의 credential set 계약: codex 정확히 1개(필수) + claude 최대 1개(mixed 필수), 그 외 타입·비JSON·중복은 거부한다 (`assert_credential_set`). claude credential이 공존하면 default 세션도 loopback key를 통해 이론상 그 credential에 닿을 수 있다 — 이 잔여 노출은 명시적으로 수용된 local trust-domain 결정이다 (이슈 #1127, #1108).
5. proxy 실행 파일과 config template은 Nix store 경로로 고정한다.
6. 일반 `claude`의 settings와 인증은 변경하지 않는다.
7. catalog에 모델이 보이는 것만으로 entitlement 성공으로 판정하지 않는다. 실제 completion이 필요하다.
8. inherited request body, effort, Unix-socket transport가 wrapper의 endpoint/model/credential 경계를 우회하지 못해야 한다.
9. byte-identical config render는 inode를 보존한다. runtime contract가 실제로 바뀌면 foreground proxy를 재시작한다.
10. user/project settings의 `fallbackModel`은 headless 고정 모델 계약을 우회하지 못하고, session effort는 wrapper-owned 값을 따른다 — 기본 `high`, 명시적 `claudex --effort` 인자(whitelist: low/medium/high/xhigh/max/ultra)만 이를 바꾸며 상속 환경값은 계속 scrub된다.
11. inherited Claude host-auth bridge와 settings `env.CLAUDE_CODE_EXTRA_BODY`는 wrapper-owned loopback/model/request 계약을 우회하지 못해야 한다.
12. request body의 `service_tier`는 wrapper-owned 값만 존재한다 — 기본은 필드 미전송(계정 기본 티어), 명시적 `claudex --fast` 인자만 pinned fast settings variant로 `"priority"`를 주입하며 상속 환경값은 계속 scrub된다.
13. `claudex login <provider> --replace`는 선택한 provider만 private staging에서 재인증한다. OAuth 전 canonical set 전체의 경로·내용 snapshot과 승격 직전 상태가 다르면 중단하고, 성공 시에도 sibling provider를 byte-for-byte 보존한다.
14. replacement는 기존 canonical 경로를 같은 filesystem의 검증된 staged 파일로 원자 교체한다. CLIProxyAPI 7.2.73은 credential 파일명을 생성할 때 계정 정보를 반영하지만 loader는 auth-dir의 JSON 내용을 파싱하고 watcher identity는 경로를 기준으로 하므로, 기존 canonical 경로를 유지해 실행 중 watcher가 provider 삭제/추가로 오인하지 않게 한다.
15. 교체 전 credential은 state 아래 `credential-backups/`에 mode `0600` private backup으로 보존한다. 자동 정리하지 않으며, 실패 시 자동 rollback에 사용한다. 성공 후 backup 삭제는 새 credential의 실제 completion 검증을 마친 운영자가 별도로 결정한다.

### 모드별 기대값 (default vs mixed)

| 축 | `claudex` (default) | `claudex --mixed` |
|---|---|---|
| main model (`--model`) | `gpt-5.6-sol` | `claude-opus-4-8` |
| subagent (`CLAUDE_CODE_SUBAGENT_MODEL`) | `gpt-5.6-sol` | `gpt-5.6-sol` |
| credential set | codex 1 (claude 0..1 허용) | codex 1 + claude 1 필수 |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 272000 | 272000 (비-claude 모델 전용이라 main 무영향) |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | 272000 | 미발행 (main의 자체 auto-compact 보존; gpt 서브는 auto-compact 없음) |
| `--fast` | 허용 | 거부 (exit 2) |
| catalog 검증 | main 1종 | main + subagent 2종 |
| claude.ai 계정 연동 (커넥터·Remote Control) | 비활성 (auth token이 로그인을 덮어 세션이 API Usage Billing으로 취급됨 — 계정에 세션이 등록되지 않아 휴대폰·타 기기 원격 접근 불가, 2026-07-17 실측) | 비활성 (동일) |

### 알려진 한계·리스크와 롤백

- **벤더 정책 의존 (전략 리스크)**: 이 브릿지는 Claude Code에 non-Anthropic 모델을 loopback proxy로 연결한다. Codex OAuth entitlement 쪽은 upstream 튜토리얼에서 공개적으로 안내된 경로지만, Anthropic 또는 OpenAI가 언제든 이 조합을 차단할 수 있다. 즉 이 경계의 수명은 두 벤더의 정책에 종속되며, 기술적 완성도와 무관하게 외부 요인으로 무력화될 수 있다.
  - **롤백 경로**: 차단이 관측되면 아직 현재 generation의 CLI가 남아 있을 때 service/process 변경 승인을 받고 `claudex proxy stop`을 먼저 실행한다. `claudex status`와 loopback 확인으로 manager가 비활성이고 listener/control socket이 사라졌음을 확인한 뒤에만 `default.nix`의 `targetHosts` allowlist에서 해당 호스트를 빼고 `nrs`를 실행한다. 그러면 활성 Home Manager generation에서 public `claudex`와 private launcher, CLIProxyAPI enabled-only closure 노출이 제거되고 descriptor와 runtime library metadata만 남는다(`lib.optionalAttrs enabled` 경계). 특히 Darwin의 private launchd definition은 runtime이 직접 bootstrap하므로, 먼저 stop하지 않고 CLI부터 제거하면 등록된 agent/process가 남을 수 있다. 이전 generation과 CLIProxyAPI Nix store 경로 자체는 garbage collection 전까지 store에 남으므로, 로컬 잔여물까지 정리하려면 generation 정리와 `nix-collect-garbage` 실행이 별도로 필요하다. credential/state는 repo 밖 state 디렉터리(darwin `$HOME/Library/Application Support/claudex`, linux `$HOME/.local/state/claudex`)에만 있다. 이 디렉터리는 proxy와 manager가 완전히 중지됐음을 확인한 뒤에만 삭제한다. 일반 `claude` 설정과 인증은 애초에 건드리지 않으므로 별도 복구가 필요 없다.
- **subagent effort 세밀 제어 불가 (기능 한계)**: wrapper는 `CLAUDE_CODE_SUBAGENT_MODEL`로 subagent 모델만 고정 모델에 맞추고, effort는 세션 단위 값 하나(기본 `high`, `claudex --effort`로 조정 가능)를 세션 전체가 공유한다. subagent effort만 별도로 낮추는 수단은 여전히 없다(pinned Claude Code CLI 자체의 제약). 대량 fan-out 워크플로우에서 토큰 소모가 부담이면 세션 effort 자체를 낮춰서 실행한다.
- **context 사용률 표시는 근사치 (기능 한계)**: pinned proxy는 SSE `message_start`에 usage `{input_tokens:0, output_tokens:0}`을 하드코딩한다 (Codex Responses API가 스트림 시작 시점에 usage를 주지 않기 때문; 실제 값은 `message_delta`에만 실림). upstream은 동일 보고(router-for-me/CLIProxyAPI#1700)를 수정 거부로 닫았고 v7.2.77까지 이 변환기는 변경이 없다. pinned CLI(2.1.210 실측)는 각 assistant 메시지에 `message_start` 스냅샷을 박제하고 "usage 합>0인 마지막 assistant 메시지"를 컨텍스트 추적 anchor로 삼으므로, 이 경로에서는 anchor가 없어 **문자수 기반 로컬 추정으로 fallback**한다(과대 경향). 여기에 미인식 모델의 200k 기본 가정이 겹치면 statusline이 조기에 "100% context used"로 포화한다. wrapper-owned `CLAUDE_CODE_MAX_CONTEXT_TOKENS=272000`은 분모를 공식 Codex catalog의 raw `context_window`로 교정하는 완화이며, 분자(로컬 추정)의 오차는 남으므로 **표시되는 %는 근사치다**. Codex 자체는 raw `272000`에 `effective_context_window_percent=95`를 적용해 `258400`을 usable window로 노출하지만, Claude Code는 별도로 output/compact headroom을 적용하므로 이 effective 값을 raw window 자리에 다시 넣지 않는다. 과거 `258000`은 2026-07-15의 Codex UI effective 표시를 반올림해 옮긴 값이라 headroom을 이중 적용했다. 공식 변경 근거는 [openai/codex#33961](https://github.com/openai/codex/pull/33961)이며, 현재값은 `codex debug models | jq '.models[] | select(.slug == "gpt-5.6-sol") | {context_window,max_context_window,effective_context_window_percent}'`로 재검증한다. [#1113](https://github.com/greenheadHQ/nixos-config/issues/1113)은 Codex catalog가 향후 `372000`으로 재상향되는 시점을 계속 추적하며, 이번 raw/effective 계층 교정으로 닫지 않는다.
- **auto-compact는 별도 env 채널이 필요 (기능 한계 → 해소)**: `CLAUDE_CODE_MAX_CONTEXT_TOKENS`는 미인식 모델의 로컬 window·사용률 분모·사전 요청 gate를 바꾸지만 compact window의 **source**는 바꾸지 않는다. pinned CLI(2.1.210)의 auto-compact 메인 경로는 source가 "auto"면(로컬 세션 가드) compact를 비활성화한다. 미인식 모델은 내장 window 테이블에 없어 명시 채널 없이는 source가 항상 "auto"이므로, claudex 세션은 auto-compact가 구조적으로 꺼져 있었다 — statusline이 "N% until auto-compact" 대신 "N% context used"로 표시되는 것이 가시적 증상이다. wrapper가 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`(공식 env 채널, 유효 100k–1M)를 같은 raw 값으로 재발행해 source를 "env"로 전환하고 임계 검사(≈ window − 출력예약 − 13k)를 활성화한다. 이 자체 reserve 때문에 raw 272k를 선언해도 compaction은 Codex의 258.4k usable window보다 먼저 시작한다. 참고로 한계 초과 시 에러 기반 회복도 기대할 수 없다: pinned proxy는 upstream 문구를 그대로 전달할 뿐 Anthropic 정식 문구로 재작성하지 않는다. 활성화는 A/B로 실측 완료(2026-07-15): `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1` + 2턴 stream-json 멀티턴에서 새 wrapper는 `status:"compacting"` 이벤트를 발동(미니 대화라 `too_few_groups`로 요약은 실패 — 트리거 사슬 동작 증거로 충분), 동일 조건에서 `AUTO_COMPACT_WINDOW`만 뺀 대조군은 compact 신호가 전무했다. 대화형 세션의 가시 신호는 statusline "% until auto-compact" 표기 전환이다.
- **대형 번들 스킬 로드가 세션의 요청 가능 여유를 소진 (용량 한계, 회피 전용)**: Claude Code 내장(번들) 스킬은 로드 시 본문 전체가 단일 레코드로 컨텍스트에 주입된다. 차단 조건은 스킬 본문 단독이 아니라 `기존 컨텍스트 + 스킬 본문 + 출력 예약분 > 사전 검사 임계`이며, `claude-api`(약 190k 토큰)는 그 자체로 측정 당시 258k window보다 작지만 로드 전 컨텍스트(약 27k)와 출력 예약분이 더해져 임계를 넘긴다. 정량 계측 대상은 `claude-api` 하나이므로, 다른 번들 스킬에 같은 결론을 적용하려면 아래 재검증 절차로 개별 계측해야 한다 (2026-07-18 실측, Claude Code `2.1.214`: 로드 전 약 27k → 로드 후 `219.1k/258k`(85%)에 `Free space` 5.9k; 세션 로그의 스킬 주입 레코드 단일 크기 812,741 bytes로 로그 전체의 97%). 대화가 1턴뿐이어도 스킬 로드만으로 `Context limit reached`가 발생하며, **auto-compact는 이 경우 구제하지 못한다** — auto-compact는 응답 수신 후 임계를 판정하는 사후 메커니즘이라, 응답이 돌아오지 않는 이 경로에서는 개입 차례 자체가 오지 않는다(위 항목의 트리거 사슬이 정상이어도 닿지 않는다). 관측된 로그는 요청 전송 전 조립 단계에서 막히는 것과 일치한다(같은 세션 로그에 `assistant` 레코드 0건, compact 계열 이벤트 0건). 다만 이 두 신호는 "응답이 기록되지 않았다"까지만 증명하므로 전송 후 응답 전 실패와 로그만으로는 구분되지 않는다 — 전송 시점을 확정하려면 CLI debug 출력이나 loopback 요청 관측이 별도로 필요하다. 설령 발동해도 compact가 줄이는 대상은 과거 대화인데 실제 대화량은 8k 수준이고 공간을 먹는 주체는 방금 로드한 스킬 본문이라 효과가 없다. 원인 축은 스킬의 출처가 아니라 **크기 대 window**다: 같은 절차에서 이 저장소의 로컬 스킬(`/playwright-cli` 등)은 Messages 5~8k로 무해하고, 순수 Claude 세션(Opus 4.8, 1M window)은 동일 스킬에서 약 20%만 차지해 정상 동작한다. 회피 수단은 세 가지다 — 해당 스킬을 트리거하지 않기, `claudex login claude`로 claude credential을 먼저 준비한 뒤 `claudex --mixed`(메인이 인식 모델이라 window가 큼)로 열기(mixed는 codex+claude credential이 모두 있어야 시작하며, 없으면 세션 시작 전에 거부된다. 단 claude credential을 canonical auth에 추가하면 default 세션도 같은 proxy와 loopback key로 그 credential에 닿을 수 있다 — 위 불변식 4와 bypassPermissions 항목이 기술한 잔여 노출과 같은 신뢰 도메인이다), 이미 걸렸다면 `/clear`. 현재 raw window는 272k로 교정됐지만 이 항목의 수치는 258k 당시 측정이므로 배포 후 같은 절차로 재계측해야 한다. 스킬 크기는 upstream 번들이라 이 저장소가 통제할 수 없으며, 코드 수정 대상이 아니다([#1140](https://github.com/greenheadHQ/nixos-config/issues/1140)에 재현 절차와 4조건 대조표 기록).
  - 재검증 (a) UI: 세션에서 `/claude-api`를 직접 호출한 뒤 `/context`의 상단 게이지와 `Free space`를 확인한다. 자동 트리거는 로드가 중단되어 상단 게이지(11%)와 카테고리 표시(`Messages` 199.6k)가 어긋나므로 슬래시 직접 호출이 정확한 계측 경로다.
  - 재검증 (b) 로그: **새 `claudex` 세션에서 대상 스킬 하나만 직접 호출한 뒤** 측정한다 — 다른 스킬 호출이나 기존 대화가 섞이면 아래 집계가 여러 레코드를 합산하거나 `assistant` 부재 검사가 성립하지 않아 결과가 조용히 오염된다. 세션 로그는 `$HOME/.claude/projects/<cwd slug>/<session-id>.jsonl`이며 해당 세션의 것을 시간순 최신으로 고른다. 스킬 주입 레코드는 `Base directory for this skill`을 포함한 줄이며, 크기와 비중은 `grep 'Base directory for this skill' <log> | wc -c`와 `wc -c <log>`로, 최대 레코드는 `awk '{print length($0)}' <log> | sort -rn | head -3`으로 산출한다. 사전 차단 여부는 `grep -oE '"type":"[^"]+"' <log> | sort | uniq -c`에 `assistant`가 없고 `grep -ciE 'compacting|too_few_groups' <log>`가 0인 것으로 확인한다.
  - 무효화 조건: 위 수치는 **Claude Code 버전, 번들 스킬 내용, 선언된 window에 종속된다**. CLI나 번들 스킬 또는 window가 바뀌면 재측정하고 `"$HOME/.local/bin/claude" --version`을 함께 기록한다. 특히 이 문서의 258k 측정은 현재 272k 계약에 그대로 외삽하지 않는다.
- **429 "All credentials are cooling down" (진단 기록, 코드 수정 대상 아님)**: 이 메시지는 pinned proxy가 credential이 quota-초과(`Quota.Exceeded`) cooldown일 때만 반환한다(v7.2.73 소스 확정) — context 초과 400은 cooldown을 유발하지 않고 즉시 반환된다(가설 기각). 2026-07-15 claudex 세션 디버그 로그 실측에서는 upstream 불안정과 얽힌 복합 패턴이 관측됐다: 30초 streaming stall → Cloudflare 520 → 재시도들이 429 cooldown 연쇄("Retrying in 4s", 1→2→4s 백오프와 부합) → 수 회 뒤 성공, 단문 응답 1건에 127초. Stage 1은 canonical credential이 정확히 1개이므로 quota cooldown = 전면 차단이며, 같은 credential pool을 쓰는 다수 백그라운드 세션이 소모·cooldown을 악화시킬 수 있다. 구조적 악화 요인: mid-stream 실패 시 proxy가 upstream `resets_at`을 무시하고 지수 백오프를 타며, `passthrough-headers` 미설정이라 `Retry-After`가 클라이언트로 전달되지 않아 Claude Code 자체 백오프로 재시도한다. 대응: 한도 회복 대기, `--effort low`/`--fast`로 소모 완화, 동시 세션 수 축소. upstream 520이 빈발하는 시간대에는 provider 자체가 degraded일 수 있다.
- **fast 티어의 조용한 폴백과 관찰 한계 (기능 한계)**: `claudex --fast`는 request body에 `service_tier:"priority"`를 주입하지만, Codex OAuth 계정에 fast 자격이 없으면 백엔드가 에러 없이 default 티어로 처리한다(upstream 실측 사례: openai/codex#14204). wrapper는 `exec` 구조라 응답을 검사할 수 없으므로 세션 내 자동 감지는 없다. 응답 쪽 관찰도 제한적이다 — pinned proxy는 Anthropic 형식으로 역변환한 응답 `usage.service_tier`에 `--fast` 유무와 무관하게 고정 `"standard"`를 넣으므로(2026-07-15 실측, fast/plain 대조 동일), **응답 usage로는 백엔드 티어 반영을 판별할 수 없다**. 검증 가능한 계약은 요청 주입까지다: loopback 캡처 서버에 fast settings variant로 headless 요청을 보내면 body에 top-level `"service_tier":"priority"`가 실리고, 기본 variant에서는 필드 자체가 없다(동일 실측). 백엔드 전달은 pinned proxy 소스의 claude→codex 변환기가 `service_tier`(fast/priority → `priority` 정규화, 그 외 drop)를 Codex 요청에 주입하고 executor가 이 필드를 삭제하지 않는 것으로 보증한다. 실제 1.5x 처리 여부는 계정 자격과 백엔드 정책에 종속되며 이 경계 밖이다.
- **bypassPermissions 기본 시작 (의도된 트레이드오프)**: wrapper는 `--dangerously-skip-permissions`로 Claude Code를 실행해 모든 세션이 bypass 모드로 시작한다. pinned CLI가 시작 플래그 없이는 세션 중 bypass 전환을 허용하지 않아 사용자가 기본 bypass를 선택했다. 이를 실제로 동작시키기 위해 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`도 `0`으로 opt-out했다 — `1`이면 pinned CLI의 allowed_non_write_users hardening이 permission mode를 default로 강제해 bypass 플래그를 조용히 무력화한다(2.1.210 실측). 잔여 노출은 세션 내 서브프로세스가 wrapper-owned loopback API key 환경값을 볼 수 있다는 것인데, 이 key는 `127.0.0.1:8317` 전용이라 영향이 국소적이다. 권한 프롬프트가 필요한 환경에서는 wrapper의 bypass 플래그를 제거해야 하며, 그 경우 세션 중 bypass 전환 옵션도 함께 사라진다.
- **`commercial-mode: true` 근거**: config template의 `commercial-mode`는 상용/라이선스 플래그가 아니라, upstream 정의상 "high-overhead request logging과 HTTP middleware 기능을 비활성화해 per-request 메모리를 줄이는" 플래그다(upstream 기본값은 `false`). 이 PoC는 credential·request 본문이 로그에 남지 않도록 request logging을 억제할 목적으로 의도적으로 `true`로 뒤집었으며, `logging-to-file`·`usage-statistics-enabled`를 모두 끄는 config-template의 보안 기본값과 같은 맥락이다. upstream 정의의 version-pinned 출처는 CLIProxyAPI `v7.2.73`의 [`config.example.yaml`](https://github.com/router-for-me/CLIProxyAPI/blob/v7.2.73/config.example.yaml)("When true, disable high-overhead request logging and HTTP middleware features to reduce per-request memory usage under high concurrency")과 [`internal/config/config.go`](https://github.com/router-for-me/CLIProxyAPI/blob/v7.2.73/internal/config/config.go)의 `CommercialMode` 필드 주석이다. 이 값이 렌더된 config에 실제로 들어가는 계약은 `tests/suites/claudex.sh`의 config-template 렌더 검증이 커버한다.

## 5. 이미 완료된 검증

2026-07-14 Gate B 구현 커밋 기준으로 다음 결과를 확인했다.

- Darwin eval tests: 통과
- targeted claudex shell tests 8개: 통과
- full shell suite: `215 pass / 0 fail` (`TEST_JOBS=4`)
- 신규 shell script `bash -n`: 통과
- 신규 shell script ShellCheck: 통과
- `nix flake check --no-build --all-systems`: 통과
- pinned CLIProxyAPI package derivation build: 통과
- generated Stage 1 runtime derivation build: 통과
- `git diff --check`: 통과

표적 테스트를 dev shell 밖에서 직접 호출하면 BSD `/bin/chmod`가 GNU `--` 옵션을 거부하므로, 자동화 셸에서 direnv가 활성화되지 않았다면 `nix develop -c`로 실행한다.

2026-07-15 현재 미커밋 수정 배치에서는 다음을 다시 확인했다.

- targeted Claudex shell tests 10개: 통과
- full shell suite: `217 pass / 0 fail`
- Darwin eval tests: 통과; no-IFD eval도 통과
- `CI=1 nix develop --command bash tests/run-all-tests.sh`: 통과 10 · SKIP 0 · 실패 0
- D22는 synthetic enabled Home Manager의 portable derivation 계약을 descriptor와 대조한다. 실제 Nix-generated command output build/read는 shell test가 담당한다.
- 관련 shell script `bash -n`: 통과
- 관련 shell script ShellCheck `--severity=warning`: 통과
- `nix flake check --no-build --all-systems`: 통과
- `git diff --check`: 통과
- `nrs`: 통과 (`81s`), 이후 `./scripts/ai/verify-ai-compat.sh` 완전 통과
- deployed descriptor/schema/target hosts와 byte-identical config inode 보존: 통과
- foreground listener는 descriptor의 pinned executable과 일치하고 status는 `service=missing`, 나머지 ready, exit `0`
- hostile request-body/effort/Unix-socket/host-auth bridge 환경과 project settings `CLAUDE_CODE_EXTRA_BODY` override를 넣은 실제 completion stdout: 정확히 `CLAUDEX_E2E_OK`; 빈 fallback 목록, wrapper-owned settings, wrapper-owned effort도 함께 실측
- foreground 종료 후 listener 없음, status exit `1`

2026-07-15 `--fast`(Codex fast 티어) 배치에서는 다음을 확인했다.

- targeted Claudex shell tests 10개(fast 케이스 포함): 통과; full shell suite `217 pass / 0 fail`; Darwin eval(IFD·no-IFD): 통과; `nix flake check --no-build --all-systems`: 통과
- `nrs` 후 `./scripts/ai/verify-ai-compat.sh` 완전 통과, 배포된 wrapper가 pinned fast settings variant(`{"env":{"CLAUDE_CODE_EXTRA_BODY":"{\"service_tier\":\"priority\"}"}}`)를 참조
- `claudex --fast=true`/`--fast=priority`: exit 2 거부, `--effort hostile` 거부 계약 유지
- `claudex --fast -p` headless completion stdout: 정확히 `CLAUDEX_E2E_OK` (exit 0)
- loopback 캡처 실측: fast settings variant로 실행한 Claude의 `/v1/messages` request body에 top-level `"service_tier":"priority"` 존재, 기본 variant에서는 필드 부재
- 응답 관찰 한계 실측: proxy 역변환 응답의 `usage.service_tier`는 `--fast` 유무와 무관하게 `"standard"` 고정 — 응답 usage는 티어 판별에 사용 불가 (§4 한계 참조)

2026-07-15 auto-compact 활성화(`CLAUDE_CODE_AUTO_COMPACT_WINDOW`) 배치에서는 다음을 확인했다.

- targeted Claudex shell tests 10개: 통과; full shell suite `217 pass / 0 fail`; Darwin eval(IFD·no-IFD): 통과; `nix flake check --no-build --all-systems`: 통과
- `nrs` 후 배포 wrapper가 `CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CLAUDEX_MAX_CONTEXT_TOKENS"` export를 포함
- **측정 방법 (재현 조건 주의)**: 아래 A/B는 배포 `claudex` 명령이 아니라 raw `$HOME/.local/bin/claude`에 wrapper 환경(loopback endpoint/key, wrapper settings, `--model gpt-5.6-sol`, `MAX_CONTEXT_TOKENS=258000`)을 부분 재현해 각 env 축을 독립 제어하며 돌린 것이다. 최종 wrapper는 `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`를 scrub하므로, PCT를 쓴 케이스(T5·T6)는 `claudex`로는 재현되지 않는 **반사실(counterfactual) 실험** — scrub이 없었다면 어떻게 되는지를 보여 scrub의 근거를 증명하는 용도다. **최종 wrapper 동작에 해당하는 재현 조건은 PCT 없는 T1·T2·T4다.**
- **확장 A/B 발동 실측 (6조건 13회, proxy 안정 시 api_retry=0으로 전부 일관)**: stream-json 멀티턴에서 `system/status`의 `status:"compacting"` 발동 유무를 대조했다. 발동(최종 wrapper 재현) — T1 실전 임계(`AUTO_COMPACT_WINDOW=100000` + ~75k 입력, **PCT override 없이** 순수 토큰 초과, ×3), T4 극단(`=1`, PCT 없이, ×2). 미발동(최종 wrapper 재현) — T2 대조군(`AUTO_COMPACT_WINDOW` 부재, `MAX_CONTEXT_TOKENS`는 유지, ×2)은 `compacting=0`. 즉 env window 채널 하나가 발동을 가른다.
- **PCT override의 window 의존성 (반사실 — scrub 근거)**: 최종 wrapper가 PCT를 scrub하기 전 상태를 재현한 실험이다. T5(`AUTO_COMPACT_WINDOW` 부재 + `PCT=1`)는 `compacting=0` — PCT override는 compact window source가 "auto"면 무효다. 반면 T6(`AUTO_COMPACT_WINDOW=258000` + `PCT=1`)은 발동. **wrapper가 window를 켜면서 상속 PCT override도 함께 살아난다는 뜻**이므로, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`·`CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`를 scrub 목록에 추가했다. scrub 반영 후에는 `claudex`로 이 두 케이스가 재현되지 않는 것이 정상이다(=상속 PCT가 무력화됨을 의미).
- 모든 발동 케이스는 headless `-p` 단발 실행이라 `compact_error:"too_few_groups"`로 요약 자체는 실패한다(압축할 누적 대화 그룹 부족 — 트리거 사슬 동작 증거로는 충분). 실제 요약 성공은 누적 메시지가 많은 대화형 세션에서만 관찰되며 이는 headless 특성이지 wrapper 계약과 무관하다.
- provider 불안정 재관측: 일부 실행에서 `api_retry` 다수 발생 후 성공 (§4의 520/429 진단과 정합); 안정 구간에서는 위 A/B가 재현적으로 동일했다.

2026-07-15 CLIProxyAPI resilience knob 배치에서는 다음을 확인했다.

- targeted Claudex shell tests 10개(config 화이트리스트 검증 포함): 통과; full shell suite `217 pass / 0 fail`; Darwin eval(IFD·no-IFD): 통과; `nix flake check --no-build --all-systems`: 통과
- 배포 전 config 실측: 기존 `config.yaml`에 `max-retry-interval`/`passthrough-headers`/`transient-error-cooldown-seconds`/`streaming`이 전부 `null`(부재=upstream 기본 비활성) — 진단 정합
- `nrs` 후 재렌더 config에 4 knob 정확 반영: `max-retry-interval:30, passthrough-headers:true, transient-error-cooldown-seconds:-1, streaming:{keepalive-seconds:15, bootstrap-retries:1}`
- **proxy 파싱 검증**: 새 config로 foreground proxy가 정상 기동(`auth/proxy/catalog=ready`) — 값 타입·중첩 구조가 치명적 파싱 오류를 내지 않았다는 증거다(예: `streaming`을 nested object로 두지 않았다면 unmarshal 실패). 단 CLIProxyAPI v7.2.73의 config 로더는 `yaml.Unmarshal`을 `KnownFields` 없이 사용해 unknown top-level key를 조용히 무시하므로, **key 이름 정합은 기동 성공이 아니라 v7.2.73 `config.example.yaml` 소스 대조로 확인**했다
- completion 회귀 없음: `claudex -p` stdout 정확히 `RESILIENCE_OK`
- 429 cooldown 흡수 효과 자체는 실제 upstream rate-limit 상황에서만 관측 가능하므로 여기서는 강제하지 않았다(실사용 관측 대상)

새 머신에서는 현재 checkout을 진실 원천으로 삼아 최소한 다음을 다시 실행한다.

```bash
./tests/run-eval-tests.sh
TEST_JOBS=4 ./tests/shell-script-tests.sh
nix flake check --no-build --all-systems
git diff --check "$(git merge-base HEAD origin/main)"..HEAD
```

Nix 명령은 프로젝트 direnv 환경 안에서 실행한다. rebuild가 필요하면 alias `nrs`만 사용하고 `darwin-rebuild` 또는 `nixos-rebuild`를 직접 실행하지 않는다.

## 6. 과거 Stage 1 검증 기록

이 절은 2026-07-14 당시 foreground-only schema 2의 역사적 증거다. 현재 사용법과 계약은 위 §3~4와 아래 §7~12를 따른다.

이전 머신에서 다음 preflight까지는 실측했다.

- macOS arm64용 pinned package와 Stage 1 runtime derivation을 실제로 build했다.
- Claude Code `2.1.209`와 headless `-p/--print` 옵션을 확인했다.
- TCP `8317`이 비어 있음을 확인했다.
- 실제 `claudex-login`을 실행하여 upstream 바이너리가 device-login URL과 일회용 코드를 출력하는 단계까지 도달했다.

그 다음 브라우저 SSO가 기존 계정 로그인 대신 신규 계정 전화 인증 흐름으로 들어갔고, 브라우저 credential manager도 잠금 해제할 수 없었다. 따라서 해당 로그인 프로세스를 `Ctrl-C`로 종료했다.

종료 후 비밀 내용을 읽지 않고 다음을 확인했다.

- canonical auth 파일 수: `0`
- 남은 `auth.login.*` staging 디렉터리 수: `0`
- TCP `8317` listener: 없음
- `cli-proxy-api` process: 없음

즉, upstream 바이너리의 device-login 진입은 실측했지만 OAuth credential은 생성되지 않았다. Foreground proxy와 Claude completion은 한 번도 실행되지 않았다. `nrs`도 실행하지 않았다. 이전 머신의 Nix store 경로와 device code는 만료·비이식 정보이므로 재사용하지 않는다.

2026-07-14 이번 재개에서는 사용자가 두 Darwin 호스트 모두 허용하는 정책을 선택했다. eval 계약을 먼저 schema 2와 `targetHosts` 목록으로 바꿔 RED를 확인한 뒤 구현을 맞췄고, 다음을 실측했다.

- `nrs`와 `./scripts/ai/verify-ai-compat.sh`: 통과
- descriptor: schema `2`, 현재 host `enabled: true`, 두 `targetHosts`, loopback `127.0.0.1:8317`, 모델 `gpt-5.6-sol`; Stage 2용 launchd plist 필드는 없음
- canonical credential: 정확히 1개, state/auth mode `0700`, credential mode `0600`, staging 0개
- listener: 정확히 1개이며 descriptor의 pinned `proxyExecutable`과 실제 process executable이 일치
- Stage 1 상태: `service=missing`, `auth=ready`, `proxy=ready`, `catalog=ready`
- headless completion stdout: 정확히 `CLAUDEX_E2E_OK`
- 종료 후: listener/process 없음, canonical credential ready, auth 파일 1개, staging 0개

그 뒤 branch를 `origin/main` 위로 rebase하고 동일 검증과 `nrs`를 다시 실행했다. Codex는 `0.144.4`로 복구됐고 AI compatibility 검증이 완전 통과했으며, listener identity와 `CLAUDEX_E2E_OK` completion도 재통과했다. 두 번째 `nrs` preview에서는 현재 branch에 없는 다른 worktree의 `headless-ssh` package가 제거되는 host-state 수렴도 함께 관찰됐다.

Proxy 시작 시 `--local-model`인데도 upstream이 antigravity version metadata를 한 번 조회했다. 이 background network의 pinned source 조사 결과는 현재 §12에 기록했다.

Gate B 완료 뒤 `run-da for_pr` FULL 1라운드는 중복 제거 기준 9건을 모두 `CONFIRMED_ISSUE`(HIGH confidence)로 판정했다. inherited Claude transport/request override, disabled-host 테스트 공백, config inode 교체로 인한 upstream file-watch 소실, Stage 2 launchd API 선구현, status 계약, production 상수 중복, fixture helper, stale handoff, source-string 결합 eval을 한 write batch로 수정했고, 그 새 변경셋 전체를 FULL 2라운드의 fresh reviewer로 다시 검토했다.

FULL 2라운드는 scratch-path 규칙을 위반한 최초 Correctness review unit을 폐기하고 fresh reviewer로 재실행했다. Regression은 `NO_FINDINGS`, 나머지 reviewer 후보를 단일 fresh Arbiter가 판정해 6건을 확정하고 1건을 기각했다. 확정한 항목은 settings fallback 우회, effort ownership, 실제 Nix wiring 테스트 공백, runtime API 계층 설명, `NO_PROXY` 중복, stale handoff였고 모두 현재 배치에 반영했다. Stage 1의 정보성 service 관찰과 foreground launcher descriptor는 현재 명세에 맞으므로 Stage 2 선구현 후보를 기각했다.

FULL 3라운드는 Regression `NO_FINDINGS` 뒤 단일 fresh Arbiter가 8개 후보를 판정했다. 확정 항목은 inherited Claude host-auth bridge scrub 누락, settings `CLAUDE_CODE_EXTRA_BODY` request-body override, Linux required CI에서 eval 중 Darwin derivation 산출물 실현, 실제 Nix command output coverage 공백, descriptor/runtime path duplication, runtime API wording, status service provenance wording, Stage 1 주석 stale 표현이다. 모두 현재 배치에 반영했고, eval 산출물 read는 no-IFD portable 계약으로 옮기고 실제 output 검증은 shell test build/read로 분리했다.

FULL 4 수렴 라운드는 Correctness `NO_FINDINGS`였고, Design reviewer가 제기한 descriptor metadata, package-internal runtime helper, 정보성 service 상태, sed fixture materializer 후보 4건은 Arbiter가 모두 `NOT_AN_ISSUE`/non-blocking으로 판정했다. thread cap 때문에 Standards/Spec code review는 병렬 subagent 대신 메인 세션에서 `HEAD` 대비 uncommitted WIP과 이 handoff/R3 판정 기준으로 수행했으며 추가 차단 finding은 없었다.

배포 중 `/tmp/nrs-state`에는 다른 worktree의 stale PID가 남아 warning이 출력됐지만 최종 `nrs`는 정상 완료했다. 앞선 검증 중 한 activation이 Shottr `defaults`에서 멈춘 적은 있으나, 최종 2026-07-15 재배포는 개입 없이 완료됐으므로 Claudex blocker로 보지 않는다. 다른 작업의 lock 파일은 삭제하지 않았다.

## 7. Phase 1 — 새 머신 기준선 확인

다음을 병렬로 확인한다.

```bash
uname -s
uname -m
command -v nrs
test -x "$HOME/.local/bin/claude"
"$HOME/.local/bin/claude" --version
rg -n 'targetHosts|enabled =|claudexShouldEnable' \
  modules/shared/programs/claudex/default.nix \
  tests/eval-tests.nix
git status --short --branch
```

기대 결과:

- OS는 Darwin, architecture는 arm64 계열이다.
- Claude Code가 `$HOME/.local/bin/claude`에 존재한다.
- enable gate가 `default.nix`와 eval test에 동일하게 표현되어 있다.
- checkout은 인수인계 문서 외 추가 변경 없이 clean하다.

### 호스트 enable 결정

새 머신이 현재 gate의 대상과 다르면 production wrapper는 의도적으로 노출되지 않는다. production runtime은 선언된 home 경로를 고정하므로, 다른 머신에서 만들어진 store 경로를 복사하거나 환경 변수로 우회하지 않는다.

변경 전에 사용자에게 다음 중 하나를 확인한다.

1. 단일 대상을 새 머신으로 이동한다.
2. 허용 대상을 복수로 확장한다.
3. 코드 변경 없이 현재 대상에서만 E2E를 수행한다.

1 또는 2를 선택하면 `default.nix`와 `tests/eval-tests.nix`의 기대값을 함께 변경하고, Phase 5의 정적 검증을 다시 통과시킨 뒤 `nrs`를 실행한다. 실제 hostname에 개인 식별자가 포함되어 있으면 그 값을 그대로 새 public diff에 추가하지 말고, 기존 host selector 구조에서 안전한 선언 방법을 먼저 설계한다.

이번 재개에서는 **2. 허용 대상을 복수로 확장**을 선택했고, 기존 flake가 이미 선언한 두 Darwin hostname을 `targetHosts`의 명시적 allowlist로 사용했다.

## 8. Phase 2 — 선언 적용과 surface 확인

enable 정책이 확정되고 필요한 변경이 검증된 뒤에만 다음을 실행한다.

```bash
nrs
./scripts/ai/verify-ai-compat.sh
```

`nrs` 후 다음을 확인한다.

```bash
jq '{schema, enabled, hostName, targetHosts, bindHost, port, model, proxyVersion, generation, lifecycle}' \
  "$HOME/.config/claudex/runtime.json"
test -x "$HOME/.local/bin/claudex"
test -x "$HOME/.local/libexec/claudex/claudex-proxy-launcher"
test ! -e "$HOME/.local/bin/claudex-login"
test ! -e "$HOME/.local/bin/claudex-status"
claudex help
```

기대 결과:

- `enabled: true`
- `bindHost: "127.0.0.1"`
- `port: 8317`
- `model: "gpt-5.6-sol"`
- `proxyVersion: "7.2.73"`
- `schema: 3`
- `lifecycle.autoStart: "first-session"`
- public 실행 surface는 `claudex` 하나이며, 도움말에 `login`, `status`, `proxy`가 표시됨

descriptor는 store 내부 plist path를 public metadata로 노출하지 않는다.

## 9. Phase 3 — Device OAuth

먼저 기존 canonical auth 파일 수만 확인하고 내용은 출력하지 않는다.

```bash
# state 경로는 플랫폼마다 다르므로(darwin: Library/Application Support, linux: XDG) descriptor에서 읽는다
auth_dir="$(jq -r .authDir "$HOME/.config/claudex/runtime.json")"
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | wc -l
```

- `0`: `claudex login`을 실행한다.
- `1`: `claudex login`이 자체 schema 검증 후 `present and schema-valid; live validity was not checked`로 종료하는지 확인한다.
- `2`: codex+claude 공존(mixed set)이면 정상이다 — `claudex status`가 auth readiness를 보고하는지 확인한다. 이 값은 로컬 credential set의 schema/file readiness만 뜻하며 upstream token 유효성은 확인하지 않는다. 같은 타입 2개거나 invalid면 아래 규칙을 따른다.
- 타입별 중복 또는 invalid: 자동 삭제·선택하지 말고 중단한 뒤 사용자에게 보고한다.

mixed 세션용 claude credential 추가는 `claudex login claude`로 수행한다 (동일 staging → 타입 검증 → 원자 승격 절차; 기존 codex credential은 건드리지 않는다).

schema-valid credential의 upstream refresh가 거부되거나 실제 completion이 401로 실패하면, 자동 삭제 대신 provider별 명시적 replacement를 사용한다.
replacement 전에는 foreground proxy와 service를 먼저 중지한다. 실행 중인 proxy가 기존 credential refresh를 뒤늦게 저장해 새 credential을 되돌리는 경쟁을 막기 위해 `claudex login ... --replace`도 lifecycle lock 안에서 proxy stopped 상태를 재확인한다.

```bash
# Codex credential만 교체
claudex login codex --replace

# Claude credential만 교체
claudex login claude --replace
```

- replacement 대상 provider가 없으면 실패하며, 먼저 `--replace` 없는 일반 로그인을 안내한다.
- OAuth 시작 전과 canonical mutation 직전에 credential set 전체를 비교한다. 그 사이 다른 프로세스가 어느 provider든 변경하면 staged 결과를 버리고 중단한다.
- 새 credential의 schema와 private mode를 검증하기 전에는 canonical set을 바꾸지 않는다.
- atomic replacement 또는 사후 검증이 실패하면 검증된 private backup으로 기존 credential을 복구한다.
- staging과 backup의 credential 본문·파일명은 출력하지 않는다.
- 실제 replacement OAuth는 계정 credential을 바꾸는 외부 상태 변경이므로 자동화 에이전트가 수행할 때 직전 사용자 승인이 필요하다.

실행:

```bash
claudex login
```

브라우저에서 device URL을 열고 현재 사용 중인 기존 OpenAI 계정으로 로그인한다. 에이전트가 UI를 대신 조작한다면 최종 OAuth 허용 버튼 바로 전에 사용자 확인을 다시 받는다. 전화번호 등록, 신규 계정 생성, CAPTCHA, credential 삭제가 나타나면 임의 진행하지 않는다.

성공 후 다음만 확인한다.

```bash
claudex login
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l
```

기대 결과는 `canonical codex credential is present and schema-valid; live validity was not checked`와 파일 수 `1`이다. 이 문구는 upstream live validity를 증명하지 않는다. credential JSON, access token, refresh token, client API key는 출력하지 않는다.

## 10. Phase 4 — Foreground proxy와 completion

### Terminal A: proxy foreground 실행

```bash
claudex proxy foreground
```

이 경로는 진단용이다. 일반 사용은 별도 terminal 없이 `claudex`가 managed proxy를 자동 시작한다. foreground terminal은 종료하지 않으며 gate가 `127.0.0.1:8317`을 소유하고 private TLS backend child를 띄워야 한다.

Nix runtime generation이 달라지면 managed mode는 다음 session 시작 때 active request를 drain한 뒤 교체한다. 사용 중이면 현재 generation을 유지하고 교체를 다음 session으로 미룬다. foreground mode는 실행 중인 terminal에서 `Ctrl-C` 후 다시 시작한다.

### Terminal B: listener 신원 확인

```bash
descriptor="$HOME/.config/claudex/runtime.json"
expected_gate="$(jq -r .gateExecutable "$descriptor")"
pid="$(lsof -tiTCP:8317 -sTCP:LISTEN)"  # darwin은 /usr/sbin/lsof, NixOS는 PATH의 lsof가 잡힌다
test -n "$pid"
ps -p "$pid" -o pid=,command=
printf 'expected=%s\n' "$expected_gate"
```

성공 조건:

- listener PID가 정확히 하나다.
- command의 executable이 descriptor의 `gateExecutable` store 경로와 일치한다.
- 다른 process가 먼저 포트를 점유했다면 즉시 중단하고 원인을 조사한다.

### 상태 출력 해석

```bash
claudex status
claudex status --json
```

아래는 준비된 managed 실행의 예시다. foreground도 나머지 readiness 값은 같지만 manager를 등록하지 않은 상태라면 `service`는 `unregistered`일 수 있다. `service`는 manager 등록 여부를 보여주는 정보이며 foreground readiness 조건은 아니다.

```json
{
  "schema": 1,
  "overall": "ready",
  "auth": "ready",
  "auth_live_validity": "unchecked",
  "service": "registered",
  "proxy": "ready",
  "readiness": "ready",
  "catalog": "ready",
  "generation": "current",
  "reason": "로컬 proxy와 모델 catalog가 준비됐습니다",
  "next_command": "claudex"
}
```

auth/proxy/catalog가 ready이면 status 명령은 exit `0`이다. `auth=ready`는 local schema/file readiness만 뜻하고 upstream refresh token의 live validity를 증명하지 않는다. 실제 인증 성공은 아래 headless completion으로 확인한다.

### Headless completion

Claude headless prompt는 stdin으로 전달한다.

```bash
e2e_dir="$(mktemp -d)"
cd "$e2e_dir"
printf '%s\n' 'Reply with exactly CLAUDEX_E2E_OK and nothing else.' \
  | claudex -p --output-format text
```

최종 stdout이 다음 한 줄이면 baseline E2E 성공이다.

```text
CLAUDEX_E2E_OK
```

이 성공은 동시에 다음을 증명한다.

1. 실제 config parser가 생성된 config를 수용했다.
2. device OAuth credential로 upstream 요청이 가능했다.
3. catalog에 선언 모델이 존재했다.
4. Claude Code가 loopback provider와 호환됐다.
5. 선언 모델로 실제 completion entitlement가 있었다.

### 종료와 refresh 보존 확인

Terminal A에서 `Ctrl-C`로 foreground proxy를 종료한다. 무차별 `pkill`은 사용하지 않는다.

```bash
lsof -nP -iTCP:8317 -sTCP:LISTEN  # darwin은 /usr/sbin/lsof, NixOS는 PATH의 lsof가 잡힌다
claudex login
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l
```

기대 결과:

- listener 없음
- canonical credential ready
- canonical auth 파일 수 `1`

managed mode는 다음처럼 제어한다.

```bash
claudex proxy start
claudex proxy stop
claudex proxy restart
claudex proxy logs
```

`stop`과 `restart`는 active request가 있으면 중단한다. 사용자가 요청 중단을 명시적으로 감수할 때만 `--force`를 붙인다.

## 11. Phase 5 — 검증과 결과 기록

### 정적·회귀 검증

```bash
./tests/run-eval-tests.sh
TEST_JOBS=4 ./tests/shell-script-tests.sh
nix flake check --no-build --all-systems
git diff --check
```

호스트 gate를 변경했다면 다음 불변식을 반드시 재검증한다.

- allowlist 밖 synthetic Home Manager activation closure에 CLIProxyAPI와 enabled-only runtime package가 들어가지 않는다.
- enabled 호스트에만 public `claudex`와 private launcher가 생긴다.
- descriptor와 eval test의 대상 정책이 일치한다.
- launchd/systemd 정의는 login/activation 시 자동 시작되지 않는다.

### E2E 기록

```text
환경: Darwin/arm64, Claude Code 2.1.209, CLIProxyAPI 7.2.73
입력: Reply with exactly CLAUDEX_E2E_OK and nothing else.
절차: device login -> foreground launcher -> listener identity -> headless claudex
기대 결과: CLAUDEX_E2E_OK
실제 결과: CLAUDEX_E2E_OK (exit 0, proxy POST /v1/messages?beta=true 200)
성공 기준: exact completion + expected listener identity + clean shutdown + credential ready
판정: PASS
```

실패 시 token이나 credential 본문을 붙이지 말고, 단계·exit code·sanitized stderr·포트 상태만 남긴다.

### 커밋 전 점검

```bash
git status --short
git diff --check
git diff --cached --stat
git diff --cached
```

인증 state는 repo 밖 state 디렉터리(darwin `$HOME/Library/Application Support/claudex`, linux `$HOME/.local/state/claudex`)에만 있어야 한다. 의도하지 않은 로컬 경로, 개인·조직 식별 정보, 브라우저 정보가 diff에 보이면 커밋하지 않는다.

## 12. #1108 source 조사 결과와 남은 실측

현재 pin CLIProxyAPI `v7.2.73`과 current upstream을 읽기 전용으로 대조한 결과:

- `--local-model`은 model catalog updater만 끈다. server는 시작 직후와 이후 3시간마다
  `https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml`
  에 credential-less `GET`을 보낸다.
- 이 요청은 `User-Agent: electron-builder`, `Cache-Control: no-cache`, body 없음, OAuth/API key 없음이다. 응답은 최대 4096바이트 YAML의 `version`만 읽는다. 따라서 egress는 provider inference/auth endpoint와 이 manifest 요청을 함께 문서화한다.
- refresh scheduler의 15분은 fallback 검사 간격이다. 실제 due time은 Codex access-token 만료 5일 전, Claude 만료 4시간 전이다.
- pinned 구현은 refresh 뒤 in-memory map을 먼저 바꾸고 persistence error를 버린다. disk write도 temp+rename이 아니라 `O_TRUNC` 직접 쓰기라 runtime memory는 새 token인데 disk/restart는 stale 또는 partial credential일 수 있다.
- transient refresh error는 5분 뒤 재시도한다. refresh 401은 credential을 unavailable/error로 표시해 scheduler에서 제거한다. request 중 401은 동기 refresh 후 같은 credential을 재시도하고, 실패하면 가능한 sibling으로 fallback한다.
- local credential file timestamp나 JSON shape는 live validity 증거가 아니다. 그래서 새 `expired` stable status enum은 추가하지 않고 `auth_live_validity=unchecked` 경계를 유지한다.
- 한 loopback bearer key에는 provider/model ACL이 없다. mixed Claude credential도 같은 local key를 가진 caller가 사용할 수 있다. 장기 실행은 원격 trust boundary를 만들지는 않지만 local key의 사용 가능 시간을 늘린다.

Lifecycle gate는 upstream을 patch하지 않고 truncate-write 잔여 위험을 줄인다. 시작 전 verified `0600` credential-set snapshot을 만들고, orderly stop 직전에 가능한 최신 schema-valid snapshot을 갱신한다. child exit 뒤 canonical set이 empty/partial/invalid면 verified snapshot으로 복구하고 재검증한다. 이 복구는 같은 filesystem의 두 directory rename을 사용하므로 그 사이의 강제 종료까지 atomic하다고 주장하지 않는다. 복구가 실패하면 manager restart loop를 막고 control caller에도 실패를 반환한다. 이것은 disk 손상 복구일 뿐 refresh worker의 완전한 quiescence나 restored credential의 live validity를 증명하지 않는다.

다음 실측은 실제 process/network/OAuth 상태를 건드리므로 실행 직전 사용자 승인을 받는다.

1. sanitized network observation으로 위 manifest egress 대조
2. 정상 refresh 뒤 metadata 갱신과 process 재시작 뒤 disk persistence 확인
3. Claude refresh 실패 관측과 `claudex login claude --replace` 수동 복구 확인

그 밖의 기존 한계인 interactive `/model` 전환 시 compact window mismatch와 `--bare`·`--agent`·`--agents`의 시작 모델 계약은 별도 추적 대상으로 남는다.

## 13. 현재 다음 행동 요약

1. 정적·fixture 검증을 통과시킨다.
2. 승인된 호스트에서 `nrs` 후 `claudex status`, session 자동 시작, graceful stop을 실측한다.
3. 별도 승인을 받은 경우에만 #1108의 network/refresh 관측을 수행한다.

진실 원천 우선: 이 문서와 실제 checkout이 다르면 파일·CLI 실측을 따르고 차이를 기록한다.
