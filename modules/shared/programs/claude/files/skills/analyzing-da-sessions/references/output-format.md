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
  "warnings": []
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
    "host_collection": {"mac": {"status": "ok", "analyzed_sessions": 5, "warnings": []}, "minipc": {"status": "ok", "analyzed_sessions": 5, "warnings": []}},
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
길이 폭증을 막기 위한 상한이며, 초과분은 `omitted_session_count`에 집계한다.

delta 입력 glob은 state directory의 `weekly-????-W??.json`만 사용한다. publish 기록
`weekly-<ISO주차>-publish.json`과 draft 파일은 glob 구조상 제외된다. publish
`success`/`failed`/`blocked`/`skipped`는 core schema에 넣지 않고 append-only publish log만
SSOT로 삼는다.

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
