# User-scope Instructions

## 사고 언어

내부 사고(thinking)를 항상 한국어로 수행하라. 영어로 사고하지 마라.

> 배경: Opus 4.6의 영어 thinking 기본 동작을 한국어로 유도. 공식 `thinking_language` 설정이 추가되면 이 섹션을 제거한다. (#345)

## skill-creator 스크립트 Override

skill-creator 플러그인의 Python 스크립트를 직접 호출하지 마라. 아래 셸 스크립트 대체물을 사용하라.

| 플러그인 원본 | Override | 용도 |
|---|---|---|
| `improve_description.py` | `~/.claude/scripts/improve-description.sh` | description 개선 |
| `run_eval.py` | `~/.claude/scripts/trigger-eval.sh` | 트리거 평가 |
| `run_loop.py` | `~/.claude/scripts/run-loop.sh` | description 최적화 loop |

위 스크립트는 모두 `claude -p` 기반이라 ANTHROPIC_API_KEY 불필요. JSON을 stdout으로 출력, 진행 상황은 stderr.

### CLI 레퍼런스

```bash
# description 개선
~/.claude/scripts/improve-description.sh \
  --skill-path <dir> --eval-results <json-file> [--history <json-file>]

# 트리거 평가 (단일)
~/.claude/scripts/trigger-eval.sh \
  --queries <path> [--skill <name>] [--reps N] [--workers N] [--timeout N] [--threshold F]

# 트리거 평가 (배치)
~/.claude/scripts/trigger-eval.sh --batch <dir>

# description 최적화 loop (run_loop.py 완전 대체)
~/.claude/scripts/run-loop.sh \
  --eval-set <json> --skill-path <dir> \
  [--max-iterations N] [--runs-per-query N] [--holdout 0.4] \
  [--num-workers N] [--timeout N] [--trigger-threshold F] \
  [--description TEXT] [--apply] [--verbose] \
  [--report auto|none|PATH] [--results-dir DIR]
```

### 필수 주의사항

- **python3 필수**: macOS에 `python`은 없다. SKILL.md에 `python`으로 적혀 있어도 `python3`으로 실행하라.
- **`run_loop.py` Override**: `run-loop.sh`가 우선. 폴백으로 skill-creator 플러그인 캐시 디렉토리에서 `python3 -m scripts.run_loop`로 실행 가능하나 ANTHROPIC_API_KEY가 필요하다.
- **플래그 추측 금지**: 처음 사용하는 CLI의 플래그는 반드시 `--help`로 먼저 확인하라. 추측한 플래그로 실행하면 API 호출이 낭비된다.

> 배경: 캐시된 skill-creator 플러그인이 구버전(Anthropic SDK 직접 호출)이라 Override 필요. (#281)
> 플러그인 업데이트 시 이 Override 제거 가능.

## Superpowers 플러그인 라우팅

Superpowers(obra/superpowers) 플러그인이 활성화되어 있다.
충돌하는 스킬은 내 하네스가 우선하며, 아래 Superpowers 스킬은 사용하지 않는다.

### 비활성화 (내 스킬이 대체)

| Superpowers 스킬 | 대체하는 내 스킬 | 이유 |
|---|---|---|
| `requesting-code-review` | `run-da` | DA 8-agent 병렬 리뷰가 더 정교 |
| `receiving-code-review` | `run-da` protocol | DA 프로토콜이 커버 |
| `dispatching-parallel-agents` | `parallel-audit` | 10-관점 전수조사가 더 정교 |
| `finishing-a-development-branch` | `create-pr` | 8-섹션 PR 템플릿 제공 |
| `executing-plans` | `plan-with-questions` | 스무고개식 계획이 더 정교 |
| `subagent-driven-development` | 해당 없음 | SDD 패턴 미사용 |

위 스킬의 트리거 키워드가 감지되면 대응하는 내 스킬을 사용한다.

### 활성 유지 (내 하네스에 없는 방법론)

`using-superpowers`, `brainstorming`, `writing-plans`, `test-driven-development`,
`systematic-debugging`, `verification-before-completion`, `using-git-worktrees`, `writing-skills`

> Superpowers 플러그인 업데이트 시 이 테이블도 함께 검토한다 (최종 검토: v5.0.5 기준).
> 갱신 절차: maintaining-skills 스킬의 Phase 2.1 "Superpowers 동기화 검증" 참조.
