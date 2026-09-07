# CLI 옵션과 모델 설정

## 명령 alias

| 명령 | 설명 |
|------|------|
| `codex e` | `codex exec`의 단축 alias |
| `codex review` | top-level alias (⚠️ `codex exec review`와 다름 — [실행 계약 Gotchas](execution-contracts.md#gotchas) 5번 참조) |
| `--yolo` | `--dangerously-bypass-approvals-and-sandbox`의 숨은 alias |

사용자 셸의 `codex`는 alias가 아니라 셸 함수이며 bypass 플래그를 자동 부착할 수 있다 —
Claude Code가 shell-snapshot으로 이 함수를 비대화형 Bash tool에도 주입하므로, 에이전트
컨텍스트가 정확히 위험 구간이다 (미검증 — 세션 실측 4건: 주입된 전역 bypass 플래그는
서브커맨드와 결합해도 파싱 에러 없이 통과해 `codex exec -s read-only` 의도를 조용히
무력화했다). 확인은 `type -a codex` — 결과가 함수/alias면 raw 호출을 중단한다. 예제는
함수를 거치지 않는 `command codex` 또는 `env CODEX_PROGRAMMATIC=1 codex` 형태만 사용하고,
`zsh -ic`로 감싸는 형태는 함수 주입을 재활성화하므로 금지한다. supervised wrapper는
스크립트 직접 실행이라 함수 면역이다.

## 호환성 매트릭스

### exec 전용 플래그 (review/resume 미지원)

| 플래그 | 설명 |
|--------|------|
| `-s, --sandbox <SANDBOX_MODE>` | 샌드박스 정책 (read-only, workspace-write, danger-full-access) — review/resume은 미지원. 셸 명령 네트워크: read-only = 항상 차단(재개방 불가) / workspace-write = 기본 차단, `-c sandbox_workspace_write.network_access=true`로 재개방 가능 / danger-full-access = 허용. OS 중립 사실 — macOS Seatbelt·NixOS bwrap 동일 실측 (2026-08-15, 0.147.0 darwin; `codex sandbox -c sandbox_mode=... -- curl` 토큰 0 재검증). 서브프로세스 프롬프트에 원격 fetch를 지시하지 말 것 — 필요한 원격 데이터는 호출자가 미리 캡처해 주입한다 |
| `-C, --cd <DIR>` | 작업 디렉토리 지정 — trusted directory 게이트(gotcha 10)의 판정 대상은 셸 cwd가 아니라 이 값이다. review에는 이 플래그가 없다 |
| `--add-dir <DIR>` | 추가 쓰기 가능 디렉토리 |
| `--approve-for-me` | 승인 요청을 workspace-write sandbox의 자동 리뷰로 라우팅 (신규, 0.147.0 — upstream #36373). 배너 `approval: on-request` + `sandbox: workspace-write`로 확인. `-s`·`--dangerously-bypass-approvals-and-sandbox`와는 clap 하드 상호 배타(파서 즉시 실패). review/resume 파서는 거부 |
| `--oss` | 오픈소스 프로바이더 |
| `--local-provider <OSS_PROVIDER>` | 로컬 프로바이더 (lmstudio/ollama) |
| `-p, --profile <CONFIG_PROFILE_V2>` | `$CODEX_HOME/<name>.config.toml`을 기본 유저 config 위에 레이어 |
| `--color <COLOR>` | 색상 설정 (always/never/auto) |

### exec · resume image 플래그

| 명령 | 플래그 | 설명 |
|------|--------|------|
| exec | `-i, --image <FILE>...` | 이미지 여러 개 첨부 가능 |
| resume | `-i, --image <FILE>` | 재개 turn에 이미지 한 개 첨부 가능 (0.144.1 help 재확인) |

review에는 image 플래그가 없다.

별도 `codex sandbox` subcommand의 공개 permission-profile 표기는
`-P, --permission-profile <NAME>`이다. `codex exec -s`의 대체 표기가 아니며
`--sandbox-permission-profile`은 0.144.1에서 `unexpected argument`로 거부된다.

### review 전용 플래그

| 플래그 | 설명 |
|--------|------|
| `--uncommitted` | 미커밋 변경 리뷰 |
| `--base <BRANCH>` | 베이스 브랜치 대비 리뷰 |
| `--commit <SHA>` | 특정 커밋 리뷰 |
| `--title <TITLE>` | 리뷰 요약 제목 (scope flag와 조합 가능, 상호 배타 규칙에 미참여. 단독 사용 시 `--commit <SHA>` 필요 — 재확인: 2026-07-10, 0.144.1) |

### exec · review · resume 공통 플래그

| 플래그 | 설명 |
|--------|------|
| `-c, --config <key=value>` | config 오버라이드 |
| `--enable <FEATURE>` | 피처 활성화 |
| `--disable <FEATURE>` | 피처 비활성화 |
| `--strict-config` | 전달한 `-c`뿐 아니라 로드된 config 전체의 미인식 필드를 오류로 처리. capability probe는 `--ignore-user-config --strict-config`로 user config drift를 격리 |
| `-m, --model <MODEL>` | 모델 선택 (생략 권장 — 기본 모델 사용, "모델 사용 원칙" 절 참조. 단 `--ignore-user-config` 동반 시 이 원칙의 예외 — 해당 행 참조) |
| `--output-schema <FILE>` | JSON Schema 출력 형식 — exec에서 동작. review는 인자를 받되 무시하는 silent no-op이다 (gotcha 11, 2026-08-15 실측); resume은 미검증 |
| `--dangerously-bypass-approvals-and-sandbox` | 샌드박스 우회 (`--yolo` 숨은 alias) |
| `--dangerously-bypass-hook-trust` | 영속 hook trust 없이 활성 hook 실행 허용 (신규, 0.142.5 — 자동화 전용, 위험) |
| `--skip-git-repo-check` | Git 저장소 체크 건너뜀 |
| `--ephemeral` | 세션 파일 미저장 |
| `--ignore-user-config` | `$CODEX_HOME/config.toml` 로드 차단 (auth만 유지). 차단되는 것은 사용자 override이고 값이 미설정이 되는 것은 아니다 — 모델 카탈로그·CLI의 fallback 기본값으로 되돌아간다. 그 폴백이 config 값과 다르면 조용히 드리프트한다 (A/B 실측 2026-08-15, 0.147.0: config `low` → 배너 `none`). model 축은 config 템플릿이 pin하지 않으므로(2026-09-05 제거) 템플릿 기인 드리프트는 없다 — 재검증: `grep -Ec '^[[:space:]]*model[[:space:]]*=' ~/.codex/config.toml`(TOML은 `model="..."`·`model   = "..."`도 유효하므로 등호 주변 공백을 허용한다)가 `0`이면 성립한다. `0`이 아니면 배포본에 값이 남아 있다는 뜻이라 그 축도 드리프트 대상이다 — 옛 템플릿 pin 잔재면 그 줄을 지우고, 앱 UI가 persist한 사용자 선택이면 그대로 두되 격리 호출에서 `-c model=`로 명시한다. 값을 고정해야 하는 호출은 `-c model_reasoning_effort=` 등으로 명시하고, 적용 여부는 시작 배너의 `reasoning effort:` 줄로 확인한다 |
| `--ignore-rules` | user/project execpolicy `.rules` 파일 로드 차단 |
| `--json` | JSONL 이벤트 출력 |
| `-o, --output-last-message <FILE>` | 마지막 메시지 파일 저장. review에서 `-o`·stdout 모두 정상 (0.144.1 실측); upstream #12502의 open 상태와 로컬 동작은 분리 — known-issues.md §2 참조 |

⚠️ 승인(approval) 관련 공개 CLI 플래그는 `review`/`resume`에는 없다. exec에는 0.147.0부터 `--approve-for-me`가 있다 (위 exec 전용 표) — 플래그 없는 기본 실행의 approval은 `never`이며 배너 `approval:` 값으로 재확인한다 (재확인: 2026-08-15, 0.147.0 배너 실측). 과거 단축 플래그 `--full-auto`는 0.147.0에서 완전 제거되어 전 서브커맨드에서 rc 2 `unexpected argument`로 즉시 실패한다 (supervised wrapper 경유도 동일 — passthrough; 변천은 known-issues "버전별 변천" 참조. `--yolo` 숨은 alias는 여전히 유효). 새 문서·스크립트에서는 아래 공개 surface를 사용한다:

- `exec`: `-s workspace-write`로 sandbox tier만 지정한다
- `review`/`resume`: 전용 sandbox 플래그가 없으므로 `config.toml`의 `sandbox_mode`를 따르거나, 필요 시 `--dangerously-bypass-approvals-and-sandbox`를 사용한다

### ⚠️ review 상호 배타 규칙

다음 4개 인자는 모두 상호 배타적 — 한 번에 하나만 사용 가능:

|  | PROMPT | --base | --uncommitted | --commit |
|---|:---:|:---:|:---:|:---:|
| PROMPT | — | ❌ | ❌ | ❌ |
| --base | ❌ | — | ❌ | ❌ |
| --uncommitted | ❌ | ❌ | — | ❌ |
| --commit | ❌ | ❌ | ❌ | — |

위반 시 에러:

```
error: the argument '[PROMPT]' cannot be used with '--base <BRANCH>'
error: the argument '--base <BRANCH>' cannot be used with '--uncommitted'
```

재확인: 2026-07-10, 0.144.1에서 여섯 pairwise 조합 모두 상호 배타 유지. upstream #7825는 closed-as-not-planned이며, 이슈 상태와 runtime 제약을 분리한다.

근본 원인과 상세 분석: [references/known-issues.md](known-issues.md) §1

## 입력 방법

programmatic 호출에는 `CODEX_PROGRAMMATIC=1`을 Codex 프로세스에 적용한다. 이 값은 CLI가
자동 주입하지 않는 caller 계약이다 (재확인: 2026-07-10, 0.144.1 환경변수 부재 실측).

| 방법 | 예시 |
|------|------|
| 인라인 문자열 (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "짧은 질의"` |
| stdin 파이프 (programmatic) | `cat prompt.md \| env CODEX_PROGRAMMATIC=1 codex-exec-supervised -s workspace-write -o result.md -` |
| stdin 마커 (raw review) | `cat prompt.md \| env CODEX_PROGRAMMATIC=1 codex exec review -` |
| 파일 리다이렉트 (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write -o result.md < prompt.md` |
| here-doc (raw 수동) | `env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write <<'EOF' ... EOF` |

PROMPT 인자와 piped stdin을 함께 주면 stdin 내용이 `<stdin>` 블록으로 append된다
(재확인: 2026-07-10, 0.144.1). `-` 마커는 PROMPT 인자의 대체재이므로 다른 PROMPT 인자와
동시에 쓰면 `error: unexpected argument '-' found`로 실패한다.

## 모델 사용 원칙

- 기본 모델: `~/.codex/config.toml`에 `model`이 있으면 그 값을, 없으면 codex 카탈로그의 priority 1 모델을 따른다 — 본 repo 템플릿은 2026-09-05부터 `model`을 pin하지 않는다 (재검증: `grep -Ec '^[[:space:]]*model[[:space:]]*=' ~/.codex/config.toml` — TOML의 등호 주변 공백 변형까지 센다).
- 리뷰 전용 모델: `review_model` 설정으로 분리 가능하다.
- 모델/review_model runtime과 unsupported-model exact response는 재검증 미수행 (0.142.5 기준 서술 유지).
- 실무 원칙:
  1. `-m`을 생략하고 기본 모델을 사용한다.
  2. `model is not supported` 오류 시 `-m`을 제거하고 재시도한다.
  3. 모델명을 매번 다르게 혼용하지 않는다.

### `-c model_reasoning_effort` / `-c service_tier` (재확인: 2026-08-15, 0.147.0)

실사용 programmatic 호출이 가장 자주 쓰는 두 config 키인데 값·검증 계약이 문서 밖에 있었다.

- 수용값 집합은 모델별로 다르다 — 정적 목록을 외우지 말고 `codex debug models`(모델 호출 없음,
  카탈로그 JSON 덤프)를 SSOT로 조회한다. effort는 모델에 따라 `low`~`xhigh`까지만인 것부터
  `max`·`ultra`까지 있는 것까지 다양하고, speed tier가 아예 없는 모델(`[]`)도 있다.
- `service_tier` 미지원/오타 값은 에러가 아니라 경고 후 silent omit이다 — stderr에
  `warning: Configured service tier ... is not advertised as supported ... and will be omitted from requests`
  한 줄을 내고 rc 0으로 계속한다 (실측). 오타·모델 교체 시 tier 지정이 조용히 사라지므로
  경고 부재를 확인한다.
- 검증 방법 분리: effort는 시작 배너의 `reasoning effort:` 줄로 확인한다. tier는 배너에 줄이
  없다 — 위 경고가 없는지로만 판정한다.
- effort는 tier와 달리 클라이언트 검증이 없어 미지원 값이 API까지 전달될 수 있다 (config 로드
  단계 거부 없음 실측; 라이브 재확인 미수행).
- 기본값을 상수로 기억하지 않는다 — 사용자 override의 정본은 `~/.codex/config.toml` 조회이고,
  `--ignore-user-config`는 그 override만 차단한다. 값이 미설정이 되는 것이 아니라 모델
  카탈로그·CLI의 fallback 기본값(`codex debug models`의 모델별 필드)으로 되돌아가며, 그 폴백이
  config 값과 다르면 조용히 드리프트한다 (공통 플래그 표 참조).
- tier 권고: 기본은 표준 tier. `fast`는 카탈로그 표기상 "1.5x speed, increased usage"로 단발
  저지연이 중요한 호출에 한정한다 — 대량 fan-out에서는 사용량 한도 창당 처리량이 표준 tier가
  유리했던 세션 실측이 있다 (배수 수치는 근거 불충분으로 미인용).
