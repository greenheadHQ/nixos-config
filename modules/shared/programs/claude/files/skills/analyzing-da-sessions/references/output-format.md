# Output Format

`analyze.py`는 같은 aggregate 객체를 입력으로 받아 markdown stdout + JSON sidecar를 동시에 렌더링한다. 두 출력의 metric 값은 절대 어긋나지 않는다 (단일 source).

## markdown stdout 형식

### Header

```markdown
# DA 세션 정량 분석 — <ISO timestamp>

| 항목 | 값 |
|------|-----|
| 호스트 | mac, minipc (또는 사용자 명시) |
| corpus | live (또는 manifest snapshot_id) |
| 분석 파일 수 | <total jsonl count> |
| Arbiter marker 세션 | <count> |
| Intensity marker 세션 | <count> |
```

### M-1: 검토 강도 verdict 분포

```markdown
## M-1: 검토 강도 verdict 분포 (n=<intensity_marker_sessions>)

| verdict | 카운트 | 비율 |
|---------|--------|------|
| FULL | 113 | 80.3% |
| LITE | 17 | 12.1% |
| SKIP | 11 | 7.6% |

```mermaid
pie title 검토 강도 verdict 분포
  "FULL" : 113
  "LITE" : 17
  "SKIP" : 11
```
```

### M-2: 판정자 verdict 분포

```markdown
## M-2: 판정자 verdict 분포 (n=<finding count, high+medium confidence subset>)

| verdict | 카운트 | 비율 |
|---------|--------|------|
| CONFIRMED_ISSUE | 4291 | 83.6% |
| NOT_AN_ISSUE | 647 | 12.6% |
| NEEDS_MORE_INFO | 134 | 2.6% |

source 분포:
- verdict_json (high): 4521 (88.1%)
- md_header (high): 312 (6.1%)
- json_unmarked (high): 89 (1.7%)
- kv (medium): 150 (2.9%)
- (nl_summary low — finding-level 분포 미포함)
```

### M-3: reviewer 묶음별 confirmed-rate

```markdown
## M-3: reviewer 묶음별 confirmed-rate

| 묶음 | total | CONFIRMED_ISSUE | confirmed-rate |
|------|-------|-----------------|----------------|
| Correctness | 1234 | 1088 | 88.2% |
| Design | 856 | 766 | 89.5% |
| Regression | 423 | 372 | 88.0% |
| Maintainability | 412 | 394 | 95.6% |
```

### M-4: 동일 세션 max severity 전이

```markdown
## M-4: 동일 세션 max severity 전이 매트릭스

| from \\ to | NONE | LOW | MEDIUM | HIGH | CRITICAL |
|------------|------|-----|--------|------|----------|
| NONE | 0 | 5 | 12 | 8 | 1 |
| LOW | 0 | 3 | 7 | 2 | 0 |
| MEDIUM | 2 | 4 | 28 | 11 | 0 |
| HIGH | 1 | 2 | 9 | 14 | 1 |
| CRITICAL | 0 | 0 | 0 | 0 | 0 |
```

### M-5: selective consistency stability_status 분포

```markdown
## M-5: selective consistency stability_status 분포 (source: round_summary_fallback, n=<selective trigger findings>)

| stability_status | 카운트 |
|------------------|--------|
| stable | 42 |
| split | 7 |
| fragmented | 2 |
```

`source` 필드는 `analyze.py:build_aggregate`가 emit하는 두 값 중 하나만 출력된다:
- `"round_summary_fallback"`: round summary `selective:` 라인이 매치된 경우.
- `"unavailable"`: `selective:` 라인 부재 시. 추정 금지 — 출력 시 분포는 빈 dict.

`fleiss-kappa.py` aggregate envelope 통합은 v1 미구현 (algorithm.md StabilitySource 섹션 참조). 따라서 `"source": "fleiss-kappa.py"`는 emit되지 않는다.

### derived statistics

```markdown
## Derived

- intensity_full_finding_zero_rate: 27.4% (FULL 113건 중 finding 0건 31건)
```

`metrics["M-2"]["source_distribution"]`은 4-tier fallback 각 source(verdict_json / md_header / json_unmarked / kv)의 추출 카운트와 confidence 라벨을 별도 키로 emit한다. 본 derived 섹션과 별개.

### Footer

```markdown
---
JSON sidecar: /tmp/analyze-da-sessions-<ISO>.json (또는 --json out= 명시 경로)
```

## JSON 스키마

자동 sidecar default 경로: `/tmp/analyze-da-sessions-<YYYY-MM-DDTHH-MM-SS>.json`. `--json out=<path>` override 가능.

```json
{
  "schema_version": "1.0",
  "captured_at": "2026-05-05T12:30:00Z",
  "hosts": ["mac", "minipc"],
  "corpus": "live",
  "metrics": {
    "M-1": {
      "denominator": "intensity_marker_sessions",
      "n": 141,
      "distribution": {"FULL": 113, "LITE": 17, "SKIP": 11},
      "percentages": {"FULL": 80.3, "LITE": 12.1, "SKIP": 7.6}
    },
    "M-2": {
      "denominator": "arbiter_marker_sessions_findings_high_medium",
      "n": 5072,
      "distribution": {"CONFIRMED_ISSUE": 4291, "NOT_AN_ISSUE": 647, "NEEDS_MORE_INFO": 134},
      "percentages": {"CONFIRMED_ISSUE": 84.6, "NOT_AN_ISSUE": 12.8, "NEEDS_MORE_INFO": 2.6},
      "source_distribution": {
        "verdict_json": {"count": 4521, "confidence": "high"},
        "md_header": {"count": 312, "confidence": "high"},
        "json_unmarked": {"count": 89, "confidence": "high"},
        "kv": {"count": 150, "confidence": "medium"}
      }
    },
    "M-3": {
      "by_bundle": {
        "Correctness": {"total": 1234, "confirmed": 1088, "confirmed_rate": 0.882},
        "Design": {"total": 856, "confirmed": 766, "confirmed_rate": 0.895},
        "Regression": {"total": 423, "confirmed": 372, "confirmed_rate": 0.880},
        "Maintainability": {"total": 412, "confirmed": 394, "confirmed_rate": 0.956}
      }
    },
    "M-4": {
      "transition_matrix": {
        "NONE->LOW": 5, "NONE->MEDIUM": 12, "NONE->HIGH": 8, "NONE->CRITICAL": 1,
        "LOW->LOW": 3, "LOW->MEDIUM": 7, "LOW->HIGH": 2,
        "MEDIUM->NONE": 2, "MEDIUM->LOW": 4, "MEDIUM->MEDIUM": 28, "MEDIUM->HIGH": 11,
        "HIGH->NONE": 1, "HIGH->LOW": 2, "HIGH->MEDIUM": 9, "HIGH->HIGH": 14, "HIGH->CRITICAL": 1
      }
    },
    "M-5": {
      "source": "round_summary_fallback",
      "n": 51,
      "distribution": {"stable": 42, "split": 7, "fragmented": 2}
    },
    "M-6": {
      "name": "persistence_key non-convergence",
      "persistence_key": "(perspective, location_identity, finding_fingerprint)",
      "key_block_count_distribution": {"2": 3},
      "top_offenders_by_session": {
        "/home/greenhead/.codex/sessions/.../rollout-abc.jsonl": [
          {
            "persistence_key": {
              "perspective": "Correctness",
              "location_identity": "modules/foo.nix:42",
              "finding_fingerprint": "sha256..."
            },
            "block_count": 2,
            "blocks": [0, 1],
            "verdicts": {"CONFIRMED_ISSUE": 2}
          }
        ]
      },
      "coverage": {"eligible_records": 120, "missing_persistence_components": 8}
    }
  },
  "derived": {
    "intensity_full_finding_zero_rate": 0.274
  },
  "diagnostics": {
    "summary": {"parse_failure": 1, "exclusion": 3, "invalid_verdict": 1, "missing_persistence_component": 8},
    "sessions": [
      {
        "path": "/home/greenhead/.claude/projects/.../session.jsonl",
        "parse_failures": ["JSON parse failed at verdict-json block"],
        "exclusions": [{"match_kind": "exclusion", "classification_reason": "placeholder verdict"}],
        "invalid_verdicts": [{"match_kind": "invalid_verdict", "verdict": "MAYBE"}],
        "diagnostics": []
      }
    ]
  },
  "traceability": {
    "coverage": {
      "sessions_total": 10,
      "complete_sessions": 8,
      "unknown_format_sessions": 1,
      "format_distribution": {"claude": 4, "codex": 5, "unknown": 1},
      "host_distribution": {"mac": 5, "minipc": 5},
      "field_presence": {"cwd": 9, "git_branch": 8, "session_id": 9},
      "missing_fields": {"git_branch": 2},
      "fallback_fields": {"rollout_filename.session_id": 1}
    },
    "sessions": []
  },
  "warnings": [],
  "corpus_exclusions": [
    {"host": "mac", "base": "~/.codex/sessions", "reason": "size_cap", "cap_mib": 50, "excluded_files": 158}
  ]
}
```

`diagnostics.summary`는 parse failure / exclusion / invalid verdict / missing persistence component
카운트의 SSOT다. `diagnostics.sessions[]`는 session별 `parse_failures`, `exclusions`,
`invalid_verdicts`, 전체 `diagnostics` 목록을 담는다. `warnings`에는 SSH 실패(host별
timeout/binary 부재/nonzero rc), manifest.json read 실패, extraction diagnostics 존재 알림 등
partial result 사유를 기록한다. v1 `analyze.py`는 `partial_failure_count`라는 별도 필드를
emit하지 않는다.

## Weekly report JSON schema v1

주간 자동화의 canonical output은 `modules/nixos/programs/da-weekly-report/files/weekly_report.py`가
생성하는 `weekly-????-W??.json`이다. top-level key는 다음으로 고정한다:

```json
{
  "schema_version": 1,
  "week": {"id": "2026-W28", "start": "2026-07-06T00:00:00+09:00", "end": "2026-07-13T00:00:00+09:00", "tz": "Asia/Seoul"},
  "analysis": {
    "sidecar_schema_version": "1.0",
    "captured_at": "2026-07-09T03:00:00+00:00",
    "hosts": ["mac", "minipc"],
    "corpus": "live",
    "session_counts": {"total": 10, "arbiter_marker_sessions": 4, "intensity_marker_sessions": 3},
    "metrics": {
      "M-1": {"denominator": "intensity_marker_sessions", "n": 3, "distribution": {"FULL": 2}, "percentages": {"FULL": 66.7}},
      "M-2": {"denominator": "arbiter_marker_sessions_findings_high_medium", "n": 7, "distribution": {"CONFIRMED_ISSUE": 5}, "percentages": {"CONFIRMED_ISSUE": 71.4}, "source_distribution": {"verdict_json": {"count": 7, "confidence": "high"}}},
      "M-3": {"by_bundle": {"Correctness": {"total": 2, "confirmed": 1, "confirmed_rate": 0.5}}},
      "M-4": {"round_key": "(session_path, block_index)", "baseline_note": "v1부터 result block 기반 새 baseline", "transition_matrix": {"HIGH->LOW": 1}},
      "M-5": {"source": "round_summary_fallback", "n": 2, "distribution": {"stable": 2}},
      "M-6": {"name": "persistence_key non-convergence", "persistence_key": "(perspective, location_identity, finding_fingerprint)", "key_block_count_distribution": {"2": 1}, "coverage": {"eligible_records": 5, "missing_persistence_components": 1}}
    },
    "derived": {"intensity_full_finding_zero_rate": 0.25},
    "warnings": []
  },
  "health": {
    "health_formula_version": 1,
    "formula_break": null,
    "run_da_path": "modules/shared/programs/claude/files/skills/run-da/",
    "document_size": {"markdown_file_count": 12, "total_line_count": 3456, "files": []},
    "drift_repair_commits": {"count": 1, "commit_hashes": ["abc123"], "commits": [], "since": "...", "until": "...", "branch": "main", "first_parent": true},
    "rule_counts": {"core_invariants_numbered": 8, "cautions_bullets": 5, "non_goals_numbered": 3, "total": 16},
    "warnings": []
  },
  "coverage": {
    "partial": false,
    "analyze_exit_code": 0,
    "diagnostics": {
      "parse_failure_count": 0,
      "exclusion_count": 0,
      "invalid_verdict_count": 0,
      "missing_persistence_component_count": 1,
      "all": {}
    },
    "diagnostic_rates": {"parse_failures_per_session": 0.0, "exclusions_per_session": 0.0},
    "marker_missing_rates": {"arbiter_marker_missing_rate": 0.6, "intensity_marker_missing_rate": 0.7},
    "m2_source_distribution": {"verdict_json": {"count": 7, "confidence": "high"}},
    "m5_source_distribution": {"round_summary_fallback": 1},
    "host_collection": {"mac": {"status": "ok", "analyzed_sessions": 5, "warnings": [], "excluded_files": 0}, "minipc": {"status": "ok", "analyzed_sessions": 5, "warnings": [], "excluded_files": 0}},
    "warnings": [],
    "health_warnings": []
  },
  "traceability": {
    "coverage": {"sessions_total": 10, "complete_sessions": 8, "unknown_format_sessions": 1},
    "sessions": [{"path": "/home/user/.codex/sessions/2026/07/09/rollout-x-y.jsonl", "host": "minipc", "format": "codex", "cwd": "/repo", "git_branch": "issue_1064", "session_id": "y", "references": {"prs": [], "issues": ["1064"], "bare_numbers": []}}],
    "omitted_session_count": 0
  },
  "deltas": {
    "previous_reports": [{"path": "/state/weekly-2026-W27.json", "week_id": "2026-W27"}],
    "items": [{"metric": "analysis.metrics.M-2.percentages.CONFIRMED_ISSUE", "unit": "%p", "current": 71.4, "comparisons": [{"week_id": "2026-W27", "previous": 70.0, "delta": 1.4}]}]
  },
  "commentary": {"text": null, "failure_reason": "codex-exec-supervised not found"},
  "provenance": {
    "analysis_sidecar_path": "/state/analyze-2026-W28.json",
    "publish_log_path": "/state/weekly-2026-W28-publish.json",
    "repo_root": "/home/greenhead/Workspace/nixos-config",
    "report_json_path": "/state/weekly-2026-W28.json",
    "report_markdown_path": "/state/weekly-2026-W28.md",
    "generated_at": "2026-07-09T03:00:00+00:00"
  }
}
```

`analysis`는 `analyze.py` sidecar의 stable subset만 정규화해서 담는다. 원본 sidecar는
embed하지 않고 `provenance.analysis_sidecar_path`로만 참조한다. `coverage`는 weekly JSON의
유일한 coverage SSOT이며, renderer/delta는 sidecar diagnostics를 직접 읽지 않는다.

Weekly markdown 구성은 다음 순서다: header table, 핵심 수치 요약, 커버리지/신뢰도,
M-1~M-6, 건강 지표 추이, 전주 delta, 소스 추적 링크, LLM 해설, warnings. Mermaid는
M-1/M-2 `pie`만 사용한다.

렌더링용 `traceability.sessions` stable subset은 기본 50개로 제한한다. 이는 GitHub comment
상한이 아니라 canonical JSON과 함께 보존하는 full local Markdown의 archival 가독성/크기를
위한 기존 상한이며, 초과분은 `omitted_session_count`에 집계한다. GitHub body 크기는 아래의
별도 bounded consumer projection이 소유한다.

delta 입력 glob은 state directory의 `weekly-????-W??.json`만 사용한다. publish 기록
`weekly-<ISO주차>-publish.json`과 draft 파일은 glob 구조상 제외된다. publish
`success`/`failed`/`blocked`/`skipped`는 core schema에 넣지 않고 append-only publish log만
SSOT로 삼는다.

## Canonical artifact와 bounded consumer projection

schema v1 canonical JSON과 consumer별 payload는 서로 다른 artifact다. canonical에서 raw
warning/diagnostics/traceability를 삭제하거나 historical report를 다시 쓰는 방식으로 outbound
크기를 줄이지 않는다. schema migration도 수행하지 않는다.

| artifact | source | 포함/역할 | UTF-8 cap |
|----------|--------|-----------|-----------|
| `weekly-<week>.json` | analyzer sidecar + health + delta + finalized commentary | schema v1 canonical, raw warning, coverage SSOT, traceability, provenance 보존 | 없음 |
| `weekly-<week>.md` | final canonical JSON과 동일 report | full local archival/rendered view. canonical JSON에서 재생성 가능 | 없음 |
| commentary input | finalize 전 draft canonical JSON | week, session counts, M-1~M-6, derived, health summary, coverage counts/rates, mac/minipc status, warning category/host counts와 omitted count, delta | 262144 bytes |
| GitHub Markdown | final canonical JSON | 핵심 요약, coverage/host, M-1~M-6, health, delta, warning counts/omitted count, sanitized commentary | 60000 bytes |

`build_consumer_summary(report)`가 두 bounded projection의 공통 allowlist seam이다. commentary,
raw warning 문자열, raw diagnostics, session path/traceability, provenance, previous report path는
summary에서 제외한다. warning count의 SSOT는 `coverage.warnings +
coverage.health_warnings`이며 `analysis.warnings`나 host별 warning 복제본을 다시 합산하지 않는다.
raw warning은 공개 표본 없이 category/host count와 `omitted_count`로만 표현한다. M-1/M-2
verdict, M-3 bundle, M-4 severity transition, M-5 status, host, source 이름은 고정 key
allowlist로 재구성한다.

`render_commentary_input(report)`는 고정 prompt, 빈 줄, deterministic compact JSON, final
newline을 하나의 renderer에서 만든다. `da-weekly-report.sh`는 이 결과를 변경 없이
`codex-exec-supervised` stdin으로 전달하며 full draft를 전달하지 않는다. projection 생성이나
byte-cap 검사가 실패하면 LLM 호출을 생략하고 generic commentary failure status로 finalize를
계속한다.

`render_github_markdown(report)`는 sanitized `commentary.text`와 public-safe failure reason만
사용한다. commentary는 완결된 escaped `<pre>...</pre>` 단위로 렌더링하고, table/section도
완전한 단위로만 생성한다. raw `head -c`, 문자 slice, 열린 table/fence를 남기는 truncation은
금지한다. 필수 section을 보존한 결과가 cap을 넘으면 `ProjectionError`로 fail-soft 처리하여
외부 호출 전에 GitHub publish를 `blocked`로 기록한다. 여러 comment 분할이나 외부 artifact로
우회하지 않는다.

함수와 CLI(`render-commentary-input`, `render-github-markdown`)는 동일 renderer를 사용한다.
output은 target과 같은 디렉토리의 unique temp file에 mode `0600`으로 flush/fsync한 뒤 atomic
replace하고, 실패 시 temp/stale outbound artifact를 정리한다. finalize는 full Markdown과
canonical JSON을 모두 먼저 render/stage하고 Markdown을 먼저, JSON을 마지막 commit marker로
replace한다. existing-final에서 full Markdown이 missing/empty이면 JSON을 변경하지 않고
`render-full-markdown`으로 현재 주차 view만 복구한다.

초기 실행 dataflow는 `draft JSON -> commentary projection -> LLM -> sanitize finalize -> final
JSON/full Markdown -> GitHub projection`이다. existing-final retry는 `final JSON -> missing full
Markdown 복구(필요 시) -> GitHub projection`이며 analyzer와 LLM을 재실행하지 않는다. canonical
SHA-256, append-only publish log, target별 latest-status, Pushover terminal 의미는 projection과
독립적으로 유지한다.

GitHub 직전 `publish-github-guarded`는 token과 모든 secret source를 경로별 정확히 한 번 읽은
snapshot을 사용한다. 동일 outbound source의 모든 문자열 값을 escaping 전에 검사하고, 같은
source를 render한 최종 body bytes를 다시 검사한다. 어느 쪽이든 exact secret match이면 body를
삭제하고 `gh`를 호출하지 않는다. strict snapshot 실패, projection/staging 실패, publisher
부재, `gh` nonzero는 각각 고정된 safe reason만 append-only publish message에 기록한다. `gh`
exit 0인데 URL이 없는 경우도 `success/url_missing` terminal이며 중복 게시를 피한다.

guarded publisher의 wire contract는 다음 조합만 허용한다. Python producer의
`GITHUB_PUBLISH_STATUS_BY_REASON`가 status/reason SSOT이며 Bash consumer는 아래 조합과 URL
규칙을 fail-closed로 검증한다.

| status | reason | URL 규칙 | 다음 실행에서 GitHub 재시도 |
|--------|--------|----------|-----------------------------|
| `success` | `ok` | 필수 | 아니오 |
| `success` | `url_missing` | 빈 값 | 아니오 |
| `failed` | `gh_nonzero` | 빈 값 | 예 |
| `blocked` | `projection_or_staging` | 빈 값 | 예 |
| `blocked` | `secret_snapshot` | 빈 값 | 예 |
| `blocked` | `outbound_secret` | 빈 값 | 예 |
| `blocked` | `publisher_unavailable` | 빈 값 | 예 |
| `blocked` | `publisher_protocol_error` | 빈 값, Bash-local | 예 |

알 수 없는 조합, tab/newline이 섞인 wire, URL 규칙 위반은 모두 body나 세부 오류를 기록하지
않고 Bash-local `blocked/publisher_protocol_error`로 정규화한다.

## GitHub Mermaid 안전 subset

PR comment / 이슈 본문에 markdown 그대로 붙여넣을 때 사용 가능한 syntax만 사용한다:

| syntax | 사용 | 회피 사유 |
|--------|------|----------|
| `pie` | OK | GitHub 정식 지원 |
| `flowchart` | OK | GitHub 정식 지원 |
| `sequenceDiagram` | OK | GitHub 정식 지원 |
| `xychart-beta` | 회피 | 실험적, 일부 환경에서 깨짐 |
| `Sankey` | 회피 | 실험적 |
| `quadrantChart` | 회피 | 실험적 |

본 Skill의 markdown 출력은 `pie` 차트만 사용한다.

## corpus 모드 출력 차이

`--corpus <manifest.json>` 호출 시 다음만 추가:
- header에 `corpus: <snapshot_id>`로 표시 (live가 아닌 pinned).
- `analyzed_files: <count>` 옆에 manifest의 `files.length`와 일치 검증 결과.
- footer에 `corpus baseline 비교: <±delta>` — manifest의 `captured_metric_summary`와 현재 측정값 차이를 PR #670 ±5% 게이트 검증에 사용.

## 자동 sidecar 경로 규칙

- default: `/tmp/analyze-da-sessions-<ISO basic format>.json` (e.g. `/tmp/analyze-da-sessions-2026-05-05T12-30-00.json`).
- `/tmp`는 NixOS/macOS 모두 재시작 시 정리됨 → 디스크 누적 위험 낮음.
- `--json out=<path>`로 override 가능 (영구 저장 의도).
- 같은 aggregate 객체를 markdown renderer + json renderer가 동시 사용 → 두 출력의 값 일치 보장.
