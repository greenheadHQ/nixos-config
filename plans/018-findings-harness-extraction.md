# Plan 018 Findings: agent harness extraction spike

## 조사 기준

- 기준 HEAD: `02396fd9` (`git rev-parse --short HEAD`)
- 브랜치: `advisor/018-harness-extraction-spike`
- 계획 기준 커밋 `fb2a8aa6` 이후 drift:
  - 명령: `git diff --stat fb2a8aa6..HEAD -- .claude/skills/ scripts/ai/ modules/shared/programs/claude/ modules/shared/programs/codex/`
  - 결과: 27 files changed, 1684 insertions(+), 121 deletions(-)
  - 큰 변화는 `issuing-codex-pairing-code` 스킬/테스트 추가와 pinning/codex 설정 주변 보강이다. 조사 대상 스냅샷은 계획 시점과 달라졌으므로, 아래 수치는 모두 `02396fd9` 기준이다.

## 사전 STOP 조건 확인

- epic #912 본문 확인:
  - 명령: `gh issue view 912 --json body`
  - 결과: 성공. 본문 `향후 고려` 절에 하네스 추출 spike가 build가 아닌 design/spike로 한정된다는 내용이 확인됐다.
- 중복 추출 작업 흔적 확인:
  - 명령: `git branch -a --list '*harness*' '*extract*' '*framework*'`
  - 결과: 현재 브랜치 `advisor/018-harness-extraction-spike`만 출력.
  - 명령: `rg -n -i "harness extraction|하네스 추출|agent framework|에이전트 개발 프레임워크|extract.*harness|harness.*extract|분리.*하네스|하네스.*분리" plans .claude/skills modules scripts tests README.md`
  - 결과: `plans/018-harness-extraction-spike.md`와 `plans/README.md`의 #955 행만 관련 출력.
  - 명령: `gh issue list --state all --search 'repo:greenheadHQ/nixos-config "하네스 추출" OR "harness extraction" OR "agent framework" OR "에이전트 개발 프레임워크"' --json number,title,state,url`
  - 결과: #955 OPEN, #912 CLOSED, #375 CLOSED. 별도 진행 중인 추출/분리 작업은 확인되지 않았다.

## 측정 명령

도메인 참조 기준:

```sh
grep -RInE 'nixos-config|greenhead|minipc|homeserver' \
  modules/shared/programs/claude/files/lib \
  modules/shared/programs/claude/files/hooks \
  modules/shared/programs/codex \
  scripts/ai .claude/skills tests
```

보조 컨벤션 참조 기준:

```sh
grep -RInE '\.claude|\.agents|modules/shared|scripts/ai|tests/|plans/|prds|lefthook|AGENTS|CLAUDE|nrs|wt|CODEX_HOME|CODEX_CONFIG_HOME|~/\.codex|~/\.claude|\.codex' \
  modules/shared/programs/claude/files/lib \
  modules/shared/programs/claude/files/hooks \
  modules/shared/programs/codex \
  scripts/ai .claude/skills tests
```

총계:

- 도메인 참조: 249라인
- 보조 컨벤션 참조: 1767라인

## Step 1: 4계층 인벤토리와 결합도 맵

| 계층 | 조사 범위 | 도메인 참조 수 | 보조 컨벤션 참조 수 | 참조 성격 | 추출 매개변수화 |
| --- | --- | ---: | ---: | --- | --- |
| 1. 훅 런타임/배포 | `modules/shared/programs/claude/files/lib`, `modules/shared/programs/claude/files/hooks`, `modules/shared/programs/codex` | 2 + 0 = 2 | 60 + 97 = 157 | `hook-runtime.sh` 자체는 범용 helper에 가깝지만, 주변 pinning 정책은 `.claude/prds`, `.claude/plans`, DA scratch, `scripts/ai`, `.claude`/`.codex` 배치와 결합. Codex 배포는 Nix `home.file`, template-owned hook command, verify oracle과 연결된다. | `hook-runtime.sh` 단독 S. pinning 정책/배포까지 포함하면 M/L. |
| 2. 게이트 스크립트 | `scripts/ai/*`, `scripts/ai/lib/*` | 5 | 281 | `verify-ai-compat.sh`가 `.claude/skills`, `.agents/skills`, `~/.codex`, shared skill 노출 정책, hook symlink suffix, USED-BY oracle을 직접 검증한다. lefthook 설치/스테이징 가드도 repo root와 `lefthook.yml` 구조를 전제한다. | L |
| 3. 스킬 본문 | `.claude/skills/*` | 207 | 311 | 실제 개인/홈서버 운용 지식이 주된 내용이다. 18개 스킬 중 `managing-minipc` 51, `running-containers` 37, `hosting-copyparty` 27, `managing-ssh` 26라인이 도메인 참조 상위다. | L |
| 4. 테스트 하네스 | `tests/*`, `tests/lib/*`, `tests/suites/*` | 35 | 1018 | `tests/lib/test-common.sh`는 도메인 키워드 0이지만 wt/nrs/Nix 배치 helper를 포함한다. suite 계층은 `modules/shared`, `.codex`, `.claude`, lefthook, wt/nrs 동작을 광범위하게 검증한다. | M/L |

주요 파일별 관찰:

- `modules/shared/programs/claude/files/lib/hook-runtime.sh`
  - 도메인 참조: 1라인 (`greenheadHQ/nixos-config/issues/759` 주석)
  - 보조 컨벤션 참조: 5라인
  - 역참조 명령: `grep -rn "hook-runtime.sh" lefthook.yml modules/ scripts/ tests/`
  - 역참조 수: 52라인. Claude/Codex pinning hooks, Codex record hooks, Nix 노출, verify oracle, `tests/suites/hook-runtime.sh`가 소비한다.
- `modules/shared/programs/claude/files/lib/pinning-patterns.sh`
  - 도메인 참조: 0라인
  - 보조 컨벤션 참조: 8라인
  - 역참조 수: 46라인. 도메인명은 없지만 `.claude/prds`, `.claude/plans`, DA scratch, body-file 정책 등 workflow taxonomy가 코드에 들어 있다.
- `tests/lib/test-common.sh`
  - 도메인 참조: 0라인
  - 보조 컨벤션 참조: 51라인
  - 역참조 수: 21라인. 공통 assertion만이 아니라 Nix `home.file`, wt wrapper, rebuild helper, `.agents/skills` ignore 등 repo fixture 설치가 섞여 있어 단독 추출 경계가 넓다.
- `scripts/ai/verify-ai-compat.sh`
  - 1621라인. 하네스 추출 후보가 아니라 현재 repo의 배치/노출 정책을 검증하는 소비자 oracle이다.

## Step 2: 최우수 후보 경계 시제

최우수 후보는 `hook-runtime.sh` 단독이다. 이유는 코드가 129라인으로 작고, 공개 함수가 `hook_load_lib`, `hook_init_scan_dir`, `hook_parse_tool_name`, `hook_parse_session_id` 네 가지로 제한되며, 도메인 참조가 주석 1라인뿐이기 때문이다.

### 공개 인터페이스 초안

패키지 이름 가정: `agent-hook-runtime`

```sh
# source 대상
. "$AGENT_HOOK_RUNTIME_LIB"

# env var primary + installed lib dir fallback
hook_load_lib ENV_VAR_NAME HOME_LIB_DIR LIB_BASENAME

# usable temp dir 생성. TMPDIR이 set-but-unusable일 때도 fallback 후보를 순회
hook_init_scan_dir [PREFIX]

# hook stdin JSON에서 공통 필드 추출. jq 실패 시 empty + exit 0
hook_parse_tool_name
hook_parse_session_id
```

초기 공개 계약:

- shell: `bash`
- 외부 명령: `mktemp`, `mkdir`, `jq` optional
- 실패 정책: 라이브러리는 정책 결정을 하지 않는다. caller가 fail-closed, warn-only, inline fallback을 선택한다.
- 비대상: `pinning-patterns.sh`, pinning guard/alert 정책, Nix/Home Manager 노출, Codex/Claude hook command template, `nrs-session-cleanup`, `session-state.sh`.

남는 결합과 매개변수화 방법:

- `hook-runtime.sh` 헤더의 `greenheadHQ/nixos-config/issues/759` 주석은 upstream changelog 또는 consumer note로 이동.
- `USED-BY` 블록은 이 repo의 `verify-ai-compat.sh` oracle과 결합되어 있다. 추출 시 upstream package는 `consumers.md`를 갖고, 이 repo는 별도 manifest 또는 grep target list로 검증해야 한다.
- `hook_init_scan_dir`의 cache fallback 경로 `codex-hooks/tmp`는 현재 Codex 이름을 내장한다. 범용화하려면 `AGENT_HOOK_CACHE_NAMESPACE` 또는 함수 인자 `cache_namespace`가 필요하다.
- 기존 단위 테스트는 `tests/suites/hook-runtime.sh`에서 유지 가능하지만 마지막 e2e(`test_pinning_guard_survives_unusable_tmpdir`)는 Codex pinning hook까지 타므로 이 repo의 통합 테스트로 남겨야 한다.

### 소비 구조 후보

1. Flake input / Nix overlay
   - 외부 repo가 `agent-hook-runtime` flake를 제공하고, 이 repo의 `modules/shared/programs/claude/default.nix`와 `modules/shared/programs/codex/default.nix`가 해당 파일을 `.claude/lib`와 `.codex/lib`로 노출한다.
   - 비용: M. Nix 소비자는 깔끔하지만, 버전 핀/업데이트/verify oracle migration이 필요하다.

2. Git subtree 또는 vendored copy
   - `modules/shared/programs/claude/files/lib/hook-runtime.sh`를 upstream에서 vendoring하고, sync commit으로 갱신한다.
   - 비용: S/M. 초기 비용은 낮지만, 수정 방향이 upstream인지 repo-local인지 매번 판단해야 한다.

3. Release artifact download
   - upstream release tarball에서 shell file만 가져와 Nix derivation으로 고정한다.
   - 비용: M. 공급망/해시 관리는 명확하지만, 현재 단일 사용자 repo에는 release 관리 표면이 새로 생긴다.

## Step 3: 판정

판정: 조건부. 지금은 추출 실행 가치가 낮고, `hook-runtime.sh` 단독만 추출 후보로 보존한다.

근거:

- 추출 가능한 leaf는 있다. `hook-runtime.sh`는 도메인 참조 1라인, 보조 컨벤션 5라인, 공개 함수 4개라 분리 자체는 가능하다.
- 그러나 실제 하네스 가치의 대부분은 `pinning-patterns.sh`, Codex hook template, `.claude`/`.agents` 스킬 투영, `verify-ai-compat.sh`, tests suite oracle에 있다. 이 부분은 repo 배치와 workflow 정책에 강하게 결합되어 있고, 단독 추출하면 오히려 versioning/배포/검증 표면이 늘어난다.
- 현재 확인된 소비자는 이 repo뿐이다. epic #912의 신중론처럼 단일 사용자 repo에 즉효 이득이 없는 상태에서 build로 전환하면 YAGNI 가능성이 높다.

재검토 트리거:

- 두 번째 실제 repo가 Claude/Codex hook runtime helper를 재사용해야 한다.
- `hook-runtime.sh`와 같은 leaf helper가 2개 이상 다른 하네스에서 반복 구현된다.
- Codex/Claude hook schema 안정화 이후, 이 repo 외부에서 pinning/guard workflow를 그대로 쓰려는 소비자가 생긴다.

트리거가 생기면 다음 plan은 전체 하네스 추출이 아니라 `hook-runtime.sh` leaf package부터 시작해야 한다. `pinning-patterns.sh`, `verify-ai-compat.sh`, 스킬 본문, tests suite 전체 추출은 그 다음 단계에서도 별도 타당성 검토가 필요하다.

## 품질 게이트 기록

- 보고서 존재 확인 대상: `test -f plans/018-findings-harness-extraction.md`
- 보고서 구조:
  - 4계층 결합도 표 존재
  - 후보 1곳(`hook-runtime.sh`) 경계 시제 존재
  - 조건부 판정과 재검토 트리거 존재
- `plans/README.md` 상태 행 갱신은 원 plan의 Done criteria에 있으나, supervisor override가 "커밋·푸시·PR·plans/README.md 상태 갱신은 supervisor가 한다"로 우선하므로 수행하지 않았다.
