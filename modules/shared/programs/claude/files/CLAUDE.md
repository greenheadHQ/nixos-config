# User-scope Instructions

## skill-creator 스크립트 Override

skill-creator 플러그인의 Python 스크립트를 직접 호출하지 마라. 아래 셸 스크립트 대체물을 사용하라.

| 플러그인 원본 | Override | 용도 |
|---|---|---|
| `improve_description.py` | `~/.claude/scripts/improve-description.sh` | description 개선 |
| `run_eval.py` | `~/.claude/scripts/trigger-eval.sh` | 트리거 평가 |

두 스크립트 모두 `claude -p` 기반이라 ANTHROPIC_API_KEY 불필요. JSON을 stdout으로 출력, 진행 상황은 stderr.

### CLI 레퍼런스

```bash
# description 개선
~/.claude/scripts/improve-description.sh \
  --skill-path <dir> --eval-results <json-file> [--history <json-file>]

# 트리거 평가 (단일)
~/.claude/scripts/trigger-eval.sh \
  --queries <path> [--skill <name>] [--reps N] [--workers N] [--timeout N]

# 트리거 평가 (배치)
~/.claude/scripts/trigger-eval.sh --batch <dir>
```

### 필수 주의사항

- **python3 필수**: macOS에 `python`은 없다. SKILL.md에 `python`으로 적혀 있어도 `python3`으로 실행하라.
- **`run_loop.py`는 Override 없음**: 원본 `run_eval.py`/`improve_description.py`를 Python import로 직접 호출하므로 ANTHROPIC_API_KEY가 필요하다. `python3 -m scripts.run_loop`으로 플러그인 캐시 디렉토리(`ls ~/.claude/plugins/cache/claude-plugins-official/skill-creator/`)에서 실행하라.
- **플래그 추측 금지**: 처음 사용하는 CLI의 플래그는 반드시 `--help`로 먼저 확인하라. 추측한 플래그로 실행하면 API 호출이 낭비된다.

> 배경: 캐시된 skill-creator 플러그인이 구버전(Anthropic SDK 직접 호출)이라 Override 필요. (#281)
> 플러그인 업데이트 시 이 Override 제거 가능.
