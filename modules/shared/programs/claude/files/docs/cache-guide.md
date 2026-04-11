# Claude Code Prompt Cache Guide

## Statusline 표시

```
⏱️ 54:32 ✓98%     ← TTL 카운트다운 + 캐시 히트율
💤 expired ✓98%   ← TTL 만료 + 마지막 히트율
```

### TTL 카운트다운

프롬프트 캐시의 남은 유효 시간. 마지막 API 응답(Stop) 이후 경과 시간 기준.

| 구독 플랜 | TTL | 카운트다운 |
|----------|-----|----------|
| Pro | 5분 | 5:00 → 0:00 |
| **Max** | **1시간** | **60:00 → 0:00** |
| API | 5분 | 5:00 → 0:00 |

**색상 의미** (TTL에 비례):

| 색상 | 5분 TTL | 1시간 TTL | 의미 |
|------|---------|----------|------|
| Green | ≥2분 | ≥24분 | 여유 있음 |
| Yellow | 1~2분 | 12~24분 | 곧 만료 |
| Red | <1분 | <12분 | 임박 |
| Muted | expired | expired | 만료됨 |

**적중 시 리셋**: TTL은 캐시가 적중(hit)할 때마다 리셋된다.
연속 대화 중에는 매 요청마다 리셋되므로 사실상 만료되지 않는다.
`expired`는 주로 유휴 상태에서 발생한다. 요청 중단(Escape/Ctrl+C) 시에도 표시될 수 있다.

### 히트율 (✓ / △ / ✗)

현재 턴의 캐시 효율. `cache_read_input_tokens`와 `cache_creation_input_tokens`로 계산.

```
히트율 = cache_read / (cache_read + cache_creation) × 100%
```

| 표시 | 히트율 | 의미 |
|------|--------|------|
| ✓98% (green) | ≥80% | 정상 — 대부분의 컨텍스트가 캐시에서 로드됨 |
| △72% (yellow) | 50~79% | 주의 — 캐시 일부 재생성. 컨텍스트 변경이 있었을 수 있음 |
| ✗12% (red) | <50% | 문제 — 캐시 대부분 재생성. 아래 원인 확인 필요 |

## 건강상태 판단

### 정상 세션의 기대치

- **일반적 세션**: 95~99% (연속 대화 시)
- **세션 초반 (cold start)**: 첫 1~3턴은 캐시 미스 정상 (캐시 빌드 중)
- **컨텍스트 compaction 직후**: 일시적으로 낮아질 수 있음 (곧 회복)

### 히트율이 낮은 원인

| 증상 | 원인 | 대응 |
|------|------|------|
| 매 턴마다 ✗ 표시 | Sentinel replacement bug | npm 패키지로 전환 |
| --resume 직후 ✗ | Resume cache miss bug | 알려진 이슈, 첫 턴만 영향 |
| 갑자기 ✗ 전환 | 대규모 컨텍스트 변경 | 정상 동작, 다음 턴에 회복 |
| 항상 ✗ | Extra Usage 다운그레이드 | 플랜 확인 (5분 TTL로 변경됨) |

### 비용 영향

캐시 미스 시 추가 비용 (500K 컨텍스트 기준):

| 상황 | 추가 비용 | 빈도 |
|------|----------|------|
| Sentinel bug 활성 | ~$0.04/요청 | 매 요청 |
| Resume 캐시 미스 | ~$0.15 | Resume 1회 |
| 정상 cold start | ~$0.15 | 세션 시작 1회 |

## 알려진 캐시 버그

### Bug 1: Sentinel Replacement

Claude Code standalone binary에 billing sentinel(`cch=00000`) 교체 로직이 존재.
대화 내용에 sentinel 문자열이 포함되면 `messages[]`의 sentinel이 먼저 교체되어
**매 요청마다 캐시 prefix가 변경** → 캐시 full rebuild.

- **영향**: 매 요청 ~$0.04 추가 (500K 컨텍스트 기준)
- **감지**: statusline에서 매 턴 ✗ (red) 표시
- **회피**: `npx @anthropic-ai/claude-code`로 실행 (standalone 대신 npm 패키지)

### Bug 2: --resume Cache Miss (v2.1.69~v2.1.96, **수정됨**)

`--resume` 시 `deferred_tools_delta`가 `messages[N]`(끝)에 추가되어
`messages[0]`의 내용이 달라짐 → 캐시 prefix 불일치 → resume 첫 요청에서 full cache miss.

- **영향**: resume마다 ~$0.15 일회성 비용 (500K 컨텍스트)
- **감지**: resume 직후 ✗, 이후 ✓로 회복
- **수정**: [v2.1.97](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md#2197)에서 수정됨

## Max 구독자 특이사항

### 1시간 TTL

Max 구독자는 1시간 캐시 TTL이 적용된다. Claude Code 소스의 `should1hCacheTTL()` 함수에서
`isClaudeAISubscriber() && !currentLimits.isUsingOverage` 조건으로 판단.

**Extra Usage 시 다운그레이드**: 5시간/7일 사용량 초과로 Extra Usage에 진입하면
1시간 → 5분 TTL로 자동 다운그레이드된다.

### TTL 감지 방법

statusline은 transcript JSONL에서 가장 최근 `cache_creation` 필드의 TTL 타입을 파싱하여
1시간/5분 TTL을 동적으로 감지한다. Extra Usage 진입 시 5분으로 자동 복귀한다.

`CLAUDE_CACHE_TTL` 환경변수로 수동 override 가능:
```bash
export CLAUDE_CACHE_TTL=300   # 5분 TTL 강제
export CLAUDE_CACHE_TTL=3600  # 1시간 TTL 강제
```

## 최적화 팁

1. **연속 대화 유지**: 유휴 시간을 TTL 내로 유지하면 캐시가 리셋되어 계속 유효
2. **npm 패키지 사용**: `npx @anthropic-ai/claude-code`로 sentinel bug 회피
3. **resume 최소화**: 가능하면 기존 세션 유지 (resume마다 캐시 미스 1회)
4. **Extra Usage 모니터링**: rate limits 진행률 바 확인 (statusline 하단)

## 레퍼런스

- [Anthropic Docs: Prompt Caching](https://docs.anthropic.com/en/docs/build-with-claude/prompt-caching)
- [Reddit: Claude Code Cache Bugs (역공학 분석)](https://www.reddit.com/r/ClaudeCode/comments/1s7mitf/)
- [GitHub: Cache TTL downgrades from 1h to 5m](https://github.com/anthropics/claude-code/issues/43566)
- [GitHub: Sentinel replacement bug](https://github.com/anthropics/claude-code/issues/40524)
- [GitHub: --resume cache miss](https://github.com/anthropics/claude-code/issues/34629)
- [cc-diag: Cache test script](https://gitlab.com/treetank/cc-diag/-/raw/c126a7890f2ee12f76d91bfb1cc92612ae95284e/test_cache.py)
