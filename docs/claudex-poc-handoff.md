# Claudex PoC 인수인계

## TL;DR

- **상황**: Claude Code 요청을 로컬 CLIProxyAPI를 통해 Codex OAuth 모델로 보내는 선언형 Stage 1 PoC가 실제 Gate B를 통과했다.
- **현재 상태**: 두 Darwin 호스트를 허용하는 descriptor schema 2가 적용됐고, device OAuth → pinned foreground proxy → `claudex` headless completion → clean shutdown을 실측했다. Gate B 뒤 `run-da for_pr` 1·2·3라운드의 확정 finding을 모두 반영했으며 현재 변경셋은 required-CI 통합 러너, `nrs`, AI compatibility, hostile settings/host-auth E2E를 통과했다. R4 수렴 판정과 Standards/Spec pre-commit review도 merge-blocker 없이 끝났다.
- **다음 액션**: 수정 배치를 커밋하고, remote branch 갱신 여부를 결정한다.
- **Blockers**: Stage 1 Gate B blocker는 없다. launchd/activation을 추가하는 Stage 2는 별도 사용자 승인 전까지 범위 밖이다.

> **대상**: `modules/shared/programs/claudex/`와 Darwin Home Manager 연결부
> **목표**: 새 머신에서 실제 device OAuth → foreground proxy → `claudex` headless completion을 재현하고, Stage 1의 Gate B 판정을 남긴다.
> **예상 소요**: 30~60분
> **난이도**: 복잡

이 문서는 이전 대화 없이 단독으로 실행할 수 있는 재개 지침이다. 기억이나 이전 터미널 출력보다 현재 브랜치, 파일시스템, CLI 실측을 우선한다.

## 1. 최종 목표와 범위

`claudex`는 기존 `claude` 설정을 수정하지 않고, 별도 wrapper 경계 안에서만 다음 경로를 강제한다.

```text
Claude Code
  -> ANTHROPIC_BASE_URL=http://127.0.0.1:8317
  -> pinned CLIProxyAPI
  -> Codex device OAuth credential
  -> gpt-5.6-sol
```

이번 재개의 최우선 목표는 **foreground E2E 한 번의 성공**이다. 다음은 아직 범위 밖이다.

- launchd agent 선언
- Home Manager activation 또는 `nrs` 후 자동 수렴
- 장기 운영용 재시작·복구 정책
- 일반 `claude` 명령이나 기존 Claude settings 변경
- Gate B 성공 전 Stage 2 구현

fake 테스트만으로는 upstream 바이너리의 실제 설정 파싱, 계정 entitlement, OAuth credential 생성·refresh, Claude Code의 provider 호환성을 증명할 수 없다. 그래서 실제 completion이 최종 성공 기준이다.

## 2. Git 기준선

- 브랜치: `codex/claudex-poc`
- rebase 후 구현 커밋: `fb911a59 feat: add declarative claudex PoC`
- rebase 후 인수인계 커밋: `167891fc docs: add claudex PoC handoff`
- Gate B 완료 커밋: `7ae7ee0 feat(claudex): complete Stage 1 Gate B`
- 현재 merge base와 `origin/main`: `c6bd515b`
- E2E 근거를 확보한 뒤 `origin/main` 위로 rebase했다. remote branch는 이전 commit ID를 가리키므로 후속 push가 필요하면 최종 검증·커밋 뒤 `--force-with-lease`를 사용한다.

새 clone 또는 브랜치가 없는 clone에서는 다음 순서로 시작한다.

```bash
git fetch origin main codex/claudex-poc
git switch --track origin/codex/claudex-poc
git status --short --branch
git log --oneline --decorate -5
git merge-base HEAD origin/main
```

이미 로컬 브랜치가 있으면 다음을 사용한다.

```bash
git fetch origin main codex/claudex-poc
git switch codex/claudex-poc
git pull --ff-only
git status --short --branch
```

커밋 전에는 개인 식별자, 조직·고객 식별자, 로컬 사용자명이 포함된 절대 경로, 내부 분류 문구가 staged diff와 커밋 메시지에 없는지 대소문자 무시로 검사한다. 런타임 credential, API key, 브라우저 계정 정보는 어떤 형태로도 커밋하지 않는다.

## 3. 구현 지도

### 선언과 패키지

- `modules/darwin/home.nix`
  - Darwin Home Manager에 `../shared/programs/claudex`를 import한다.
- `modules/shared/programs/claudex/default.nix`
  - 호스트 enable gate, state 경로, loopback 주소, 포트, 모델, runtime package, descriptor를 선언한다.
  - 모든 Darwin 호스트에는 descriptor와 runtime library가 생긴다.
  - enable된 호스트에만 `claudex`, `claudex-login`, `claudex-status`, proxy launcher가 노출된다.
  - Stage 1에는 launchd와 activation이 의도적으로 없다.
- `modules/shared/programs/claudex/package.nix`
  - CLIProxyAPI prebuilt archive를 고정하고 release layout을 검증한 뒤 바이너리 하나만 설치한다.
- `modules/shared/programs/claudex/cli-proxy-api-pin.json`
  - 버전 `7.2.73`, Darwin arm64 asset, SRI를 고정한다.
- `modules/shared/programs/claudex/files/verify-release-layout.sh`
  - archive 최상위 5개 항목의 이름과 type을 정확히 검증한다.

### 런타임

- `modules/shared/programs/claudex/files/claudex-runtime.sh`
  - state 생성, 권한 검증, config 렌더링, credential 검증, loopback curl, lock을 담당한다.
  - 동일한 config 재렌더링은 기존 파일 inode를 보존하고, 실제 내용 변경만 원자적으로 교체한다.
  - bind host에서 `NO_PROXY` 값을 파생해 wrapper, login, launcher, loopback curl이 같은 계약을 사용한다.
  - production variant는 home/state/tool/template 경로를 Nix 치환값으로 고정하고 환경 변수 override를 받지 않는다.
- `modules/shared/programs/claudex/files/claudex-login.sh`
  - device OAuth를 임시 staging 디렉터리에서 수행한다.
  - 정확히 하나의 유효 credential만 canonical auth 디렉터리로 원자적으로 승격한다.
  - 중단·실패 시 staging을 정리한다.
- `modules/shared/programs/claudex/files/claudex-proxy-launcher.sh`
  - private state와 credential을 검증하고, 정리된 환경에서 고정된 proxy 바이너리를 foreground로 실행한다.
- `modules/shared/programs/claudex/files/claudex.sh`
  - provider/model/settings 관련 사용자 override를 거부한다.
  - `CLAUDE_CODE_EXTRA_BODY`, inherited `CLAUDE_CODE_EFFORT_LEVEL`, `ANTHROPIC_UNIX_SOCKET`, Claude host-auth bridge 환경을 포함한 endpoint/request/transport override 환경을 scrub한다.
  - wrapper-owned settings 파일로 `CLAUDE_CODE_EXTRA_BODY`를 `{}`로 고정해 user/project settings의 request-body override를 중화한다.
  - 빈 CLI fallback 목록으로 settings의 `fallbackModel`을 마스킹하고, wrapper-owned `CLAUDE_CODE_EFFORT_LEVEL`을 다시 설정한다.
  - loopback catalog에서 선언 모델을 확인한 뒤 `$HOME/.local/bin/claude`를 실행한다.
  - model은 `gpt-5.6-sol`로 고정한다. effort는 기본 `high`이며, 명시적 `claudex --effort <low|medium|high|xhigh|max|ultra>` 인자만 세션 값을 바꾼다. `ultra`는 pinned CLI가 argv에서 warn-then-ignore하므로 env 값으로만 전달한다.
  - `--dangerously-skip-permissions`로 실행해 세션이 항상 bypassPermissions로 시작한다 (pinned CLI는 시작 플래그 없이 세션 중 bypass 전환이 불가능).
- `modules/shared/programs/claudex/files/claudex-status.sh`
  - launchd service, auth, proxy, catalog 상태를 네 줄로 출력한다.
  - Stage 1 성공 조건은 auth/proxy/catalog ready이며, launchd service는 정보성 상태다.
- `modules/shared/programs/claudex/files/config-template.json`
  - runtime-owned host/port/pprof slot은 비워 두고, remote management·plugin·파일 로그·통계 비활성화를 선언한다.
  - `default.nix`의 단일 runtime contract가 최종 `127.0.0.1:8317`, 모델, label, pprof 주소를 runtime과 config에 함께 주입한다.

### 검증 연결

- `tests/suites/claudex.sh`: fake boundary, state mode, credential shape, wrapper scrub, wrapper-owned settings, 파생 runtime 계약, 실제 Nix-generated command output, layout drift, synthetic disabled Home Manager closure를 검증한다. fixture materialization 뒤 미치환 placeholder가 하나라도 남으면 실패한다.
- `tests/shell-script-tests.sh`: 위 suite의 10개 테스트를 전체 shell suite에 등록한다.
- `tests/eval-tests.nix`: descriptor, 실제·synthetic host 노출, pin, config, no-launchd/no-activation 계약과 portable Nix derivation 계약을 평가한다. 실제 command output 내용은 shell test가 build/read한다.
- `lefthook.yml`과 `scripts/ai/check-lefthook-staged-config.sh`: JSON pin/template 변경이 eval 검증을 타도록 한다.

## 4. 고정 계약

| 항목 | 값 |
|---|---|
| Proxy | CLIProxyAPI `7.2.73`, Darwin arm64 |
| Bind | `127.0.0.1:8317` |
| 모델 | `gpt-5.6-sol` |
| Runtime state | `$HOME/Library/Application Support/claudex` |
| Descriptor | `$HOME/.config/claudex/runtime.json`, schema `2` |
| Enabled hosts | `greenhead-MacBookPro`, `work-MacBookPro` |
| Claude 실행 파일 | `$HOME/.local/bin/claude` |
| Service label | `org.nix-community.home.claudex-proxy` |
| Stage 1 service | 없음; foreground launcher만 존재 |

보안·정합성 불변식:

1. listener는 loopback만 사용한다.
2. client API key는 state 디렉터리의 mode `0600` 파일이며, 정확히 64자의 lowercase hex여야 한다.
3. state/auth/runtime 디렉터리는 symlink가 아니어야 하고 private mode를 유지해야 한다.
4. canonical auth에는 정확히 하나의 유효 Codex credential만 허용한다.
5. proxy 실행 파일과 config template은 Nix store 경로로 고정한다.
6. 일반 `claude`의 settings와 인증은 변경하지 않는다.
7. catalog에 모델이 보이는 것만으로 entitlement 성공으로 판정하지 않는다. 실제 completion이 필요하다.
8. inherited request body, effort, Unix-socket transport가 wrapper의 endpoint/model/credential 경계를 우회하지 못해야 한다.
9. byte-identical config render는 inode를 보존한다. runtime contract가 실제로 바뀌면 foreground proxy를 재시작한다.
10. user/project settings의 `fallbackModel`은 headless 고정 모델 계약을 우회하지 못하고, session effort는 wrapper-owned 값을 따른다 — 기본 `high`, 명시적 `claudex --effort` 인자(whitelist: low/medium/high/xhigh/max/ultra)만 이를 바꾸며 상속 환경값은 계속 scrub된다.
11. inherited Claude host-auth bridge와 settings `env.CLAUDE_CODE_EXTRA_BODY`는 wrapper-owned loopback/model/request 계약을 우회하지 못해야 한다.

### 알려진 한계·리스크와 롤백

- **벤더 정책 의존 (전략 리스크)**: 이 브릿지는 Claude Code에 non-Anthropic 모델을 loopback proxy로 연결한다. Codex OAuth entitlement 쪽은 upstream 튜토리얼에서 공개적으로 안내된 경로지만, Anthropic 또는 OpenAI가 언제든 이 조합을 차단할 수 있다. 즉 이 경계의 수명은 두 벤더의 정책에 종속되며, 기술적 완성도와 무관하게 외부 요인으로 무력화될 수 있다.
  - **롤백 경로**: 차단이 관측되면 `default.nix`의 `targetHosts` allowlist에서 해당 호스트를 빼고 `nrs`를 실행한다. 그러면 활성 Home Manager generation에서 네 실행 surface와 CLIProxyAPI enabled-only closure 노출이 즉시 제거되고 descriptor와 runtime library metadata만 남는다(`lib.optionalAttrs enabled` 경계). 단, 이전 generation과 CLIProxyAPI Nix store 경로 자체는 garbage collection 전까지 store에 남으므로, 로컬 잔여물까지 정리하려면 generation 정리와 `nix-collect-garbage` 실행이 별도로 필요하다. credential/state는 repo 밖 `$HOME/Library/Application Support/claudex`에만 있으므로 그 디렉터리를 지우면 로컬 흔적도 제거된다. 일반 `claude` 설정과 인증은 애초에 건드리지 않으므로 별도 복구가 필요 없다.
- **subagent effort 세밀 제어 불가 (기능 한계)**: wrapper는 `CLAUDE_CODE_SUBAGENT_MODEL`로 subagent 모델만 고정 모델에 맞추고, effort는 세션 단위 값 하나(기본 `high`, `claudex --effort`로 조정 가능)를 세션 전체가 공유한다. subagent effort만 별도로 낮추는 수단은 여전히 없다(pinned Claude Code CLI 자체의 제약). 대량 fan-out 워크플로우에서 토큰 소모가 부담이면 세션 effort 자체를 낮춰서 실행한다.
- **bypassPermissions 기본 시작 (의도된 트레이드오프)**: wrapper는 `--dangerously-skip-permissions`로 Claude Code를 실행해 모든 세션이 bypass 모드로 시작한다. pinned CLI가 시작 플래그 없이는 세션 중 bypass 전환을 허용하지 않아 사용자가 기본 bypass를 선택했다. 이를 실제로 동작시키기 위해 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`도 `0`으로 opt-out했다 — `1`이면 pinned CLI의 allowed_non_write_users hardening이 permission mode를 default로 강제해 bypass 플래그를 조용히 무력화한다(2.1.210 실측). 잔여 노출은 세션 내 서브프로세스가 wrapper-owned loopback API key 환경값을 볼 수 있다는 것인데, 이 key는 `127.0.0.1:8317` 전용이라 영향이 국소적이다. 권한 프롬프트가 필요한 환경에서는 wrapper의 bypass 플래그를 제거해야 하며, 그 경우 세션 중 bypass 전환 옵션도 함께 사라진다.
- **`commercial-mode: true` 근거**: config template의 `commercial-mode`는 상용/라이선스 플래그가 아니라, upstream 정의상 "high-overhead request logging과 HTTP middleware 기능을 비활성화해 per-request 메모리를 줄이는" 플래그다(upstream 기본값은 `false`). 이 PoC는 credential·request 본문이 로그에 남지 않도록 request logging을 억제할 목적으로 의도적으로 `true`로 뒤집었으며, `logging-to-file`·`usage-statistics-enabled`를 모두 끄는 config-template의 보안 기본값과 같은 맥락이다. upstream 정의의 version-pinned 출처는 CLIProxyAPI `v7.2.73`의 [`config.example.yaml`](https://github.com/router-for-me/CLIProxyAPI/blob/v7.2.73/config.example.yaml)("When true, disable high-overhead request logging and HTTP middleware features to reduce per-request memory usage under high concurrency")과 [`internal/config/config.go`](https://github.com/router-for-me/CLIProxyAPI/blob/v7.2.73/internal/config/config.go)의 `CommercialMode` 필드 주석이다. 이 값이 렌더된 config에 실제로 들어가는 계약은 `tests/suites/claudex.sh`의 config-template 렌더 검증이 커버하며, 실제 로그 억제 동작의 런타임 실측은 upstream 바이너리 동작 범위라 §12의 Stage 2 전 조사(#1108)와 함께 다룬다.

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

새 머신에서는 현재 checkout을 진실 원천으로 삼아 최소한 다음을 다시 실행한다.

```bash
./tests/run-eval-tests.sh
TEST_JOBS=4 ./tests/shell-script-tests.sh
nix flake check --no-build --all-systems
git diff --check "$(git merge-base HEAD origin/main)"..HEAD
```

Nix 명령은 프로젝트 direnv 환경 안에서 실행한다. rebuild가 필요하면 alias `nrs`만 사용하고 `darwin-rebuild` 또는 `nixos-rebuild`를 직접 실행하지 않는다.

## 6. 이전 중단 상태와 이번 재개 결과

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

Proxy 시작 시 `--local-model`인데도 upstream이 antigravity version metadata를 한 번 조회했다. completion과 무관한 background network 범위는 Stage 2 전 별도 조사 대상으로 남긴다.

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
jq '{schema, enabled, hostName, targetHosts, bindHost, port, model, proxyVersion, hasLaunchAgentPlist: has("launchAgentPlist")}' \
  "$HOME/.config/claudex/runtime.json"
test -x "$HOME/.local/bin/claudex"
test -x "$HOME/.local/bin/claudex-login"
test -x "$HOME/.local/bin/claudex-status"
test -x "$HOME/.local/libexec/claudex/claudex-proxy-launcher"
```

기대 결과:

- `enabled: true`
- `bindHost: "127.0.0.1"`
- `port: 8317`
- `model: "gpt-5.6-sol"`
- `proxyVersion: "7.2.73"`
- `hasLaunchAgentPlist: false`
- 네 실행 surface가 모두 executable

Stage 1 descriptor는 Stage 2 전용 launch-agent 필드를 미리 노출하지 않는다.

## 9. Phase 3 — Device OAuth

먼저 기존 canonical auth 파일 수만 확인하고 내용은 출력하지 않는다.

```bash
auth_dir="$HOME/Library/Application Support/claudex/auth"
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null | wc -l
```

- `0`: `claudex-login`을 실행한다.
- `1`: `claudex-login`이 자체 schema 검증 후 ready로 종료하는지 확인한다.
- `2` 이상 또는 invalid: 자동 삭제·선택하지 말고 중단한 뒤 사용자에게 보고한다.

실행:

```bash
claudex-login
```

브라우저에서 device URL을 열고 현재 사용 중인 기존 OpenAI 계정으로 로그인한다. 에이전트가 UI를 대신 조작한다면 최종 OAuth 허용 버튼 바로 전에 사용자 확인을 다시 받는다. 전화번호 등록, 신규 계정 생성, CAPTCHA, credential 삭제가 나타나면 임의 진행하지 않는다.

성공 후 다음만 확인한다.

```bash
claudex-login
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l
```

기대 결과는 `canonical Codex credential is already ready`와 파일 수 `1`이다. credential JSON, access token, refresh token, client API key는 출력하지 않는다.

## 10. Phase 4 — Foreground proxy와 completion

### Terminal A: proxy foreground 실행

```bash
"$HOME/.local/libexec/claudex/claudex-proxy-launcher"
```

이 터미널은 종료하지 않는다. launcher가 JSON-as-YAML config를 실제로 읽고 `127.0.0.1:8317`에 bind해야 한다.

Nix runtime contract나 generated config가 실제로 달라졌다면 기존 foreground proxy를 먼저 종료하고 launcher를 다시 시작한다. byte-identical `claudex` 호출은 config inode를 보존하지만, 내용이 달라지는 원자적 교체 뒤에는 pinned upstream의 file-watch 재등록을 신뢰하지 않는다.

### Terminal B: listener 신원 확인

```bash
descriptor="$HOME/.config/claudex/runtime.json"
expected_proxy="$(jq -r .proxyExecutable "$descriptor")"
pid="$(/usr/sbin/lsof -tiTCP:8317 -sTCP:LISTEN)"
test -n "$pid"
ps -p "$pid" -o pid=,command=
printf 'expected=%s\n' "$expected_proxy"
```

성공 조건:

- listener PID가 정확히 하나다.
- command의 executable이 descriptor의 `proxyExecutable` store 경로와 일치한다.
- 다른 process가 먼저 포트를 점유했다면 즉시 중단하고 원인을 조사한다.

### 상태 출력 해석

```bash
claudex-status
```

Stage 1의 foreground 실행에서는 다음이 기대된다.

```text
service=missing
auth=ready
proxy=ready
catalog=ready
```

launchd가 아직 없으므로 `service=missing`은 정상이다. auth/proxy/catalog가 ready이면 status 명령은 exit `0`이며 foreground Stage 1 readiness gate로 사용할 수 있다.

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
/usr/sbin/lsof -nP -iTCP:8317 -sTCP:LISTEN
claudex-login
find "$auth_dir" -mindepth 1 -maxdepth 1 -type f -print | wc -l
```

기대 결과:

- listener 없음
- canonical credential ready
- canonical auth 파일 수 `1`

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
- enabled 호스트에만 네 실행 surface가 생긴다.
- descriptor와 eval test의 대상 정책이 일치한다.
- Stage 1에는 launchd agent와 activation이 없다.

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

인증 state는 repo 밖 `$HOME/Library/Application Support/claudex`에만 있어야 한다. 의도하지 않은 로컬 경로, 개인·조직 식별 정보, 브라우저 정보가 diff에 보이면 커밋하지 않는다.

## 12. 남아 있는 미지와 Stage 2 조건

Gate B 성공 후 아직 직접 확인해야 하는 항목:

- 15분 refresh 주기를 실제로 지난 OAuth refresh persistence와 실패 복구
- `--bare`, `--agent`, `--agents`, interactive `/model`이 고정 모델 계약을 우회하는지
- startup에서 관찰된 antigravity version metadata 조회를 포함한 upstream background network 동작 범위
- listener PID/executable provenance를 자동화할 방법

이 중 refresh persistence와 upstream background network(egress) 규명은 [#1108](https://github.com/greenheadHQ/nixos-config/issues/1108)로, PR 리뷰에서 분리한 경미 runtime 개선(stat 특수비트 비교, layout drift 메시지)은 [#1109](https://github.com/greenheadHQ/nixos-config/issues/1109)로 추적한다.

Baseline E2E가 성공해도 곧바로 Stage 2를 구현하지 않는다. 사용자 승인 후 다음을 별도 설계한다.

1. launchd agent와 pinned `ProgramArguments`
2. loaded plist, PID, store executable provenance 검증
3. Home Manager activation의 best-effort 수렴과 `nrs` 후 service-aware 검증
4. 최초 bootstrap의 2-pass 필요 여부
5. 장애·재시작·credential refresh 관찰

구현 완료 뒤에는 `run-da for_pr`로 diff 품질을 검증하고, 범위가 넓어졌다면 `run-da audit`로 회귀와 side effect를 추가 점검한다.

## 13. 현재 다음 행동 요약

1. 현재 수정 배치를 커밋한다.
2. rebase로 remote branch와 commit ID가 달라졌으므로 push는 최종 사용자 확인 뒤 `--force-with-lease`로 수행한다.
3. Stage 2는 사용자 승인 전 구현하지 않는다.

진실 원천 우선: 이 문서와 실제 checkout이 다르면 파일·CLI 실측을 따르고 차이를 기록한다.
