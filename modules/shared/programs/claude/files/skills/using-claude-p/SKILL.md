---
name: using-claude-p
description: >-
  Run Claude Code non-interactively with claude -p for headless automation, JSON parsing, SSH
  execution, or CLI flag troubleshooting. Use when requests mention `claude -p` or
  `비대화형/headless claude`. Use using-codex-exec for Codex subprocesses.
---

# Claude Code 비대화형 모드 (`claude -p`) 사용

상세 flag·gotcha의 SSOT는 [flag-matrix.md](references/flag-matrix.md)와
[gotchas.md](references/gotchas.md)이며, 본문은 선택 기준과 성공 계약만 요약한다.

## 작성 기준

- 확인 날짜: 2026-07-10
- 확인 버전: Claude Code v2.1.206
- 재검증: `claude --version && claude --help && claude -p --help`

print 모드는 workspace trust dialog를 생략하고 invalid settings를 조용히 무시할 수 있다
(2.1.206 help). 자동화 전에는 settings를 별도 검증한다.

## 범위

| 포함 | 제외 |
|------|------|
| `claude -p` 비대화형 실행 | 대화형 TUI 사용법 |
| `--output-format json` 파싱 | Claude Code hooks/plugins 설정 |
| harness 셀프테스트 (T1~T8) | Codex CLI 실행 → `using-codex-exec` |
| SSH 경유 크로스머신 실행 | Codex settings/skill projection (repo 정책/검증 스크립트 참조) |
| 숨겨진 동작 | Python/TS SDK (별도 스킬 분리 대상) |
| 세션 체이닝 (`--resume`) | |

## 의사결정 트리

```
claude -p 실행이 필요한가?
│
├─ 도구 실행이 필요한가?
│  ├─ YES
│  │    도구를 제한할 필요가 있나?
│  │    ├─ YES → --allowed-tools "Bash,Read" (stdin 필수!)
│  │    │         ⚠️ --dangerously-skip-permissions와 함께 쓰면 제한 무효
│  │    └─ NO → --dangerously-skip-permissions 추가
│  └─ NO → 기본 실행 (권한 플래그 불필요)
│
├─ 출력을 프로그래밍적으로 파싱할 필요가 있나?
│  ├─ YES → --output-format json (top-level 이벤트 배열, 2.1.206 성공 경로 실측)
│  │         배열/객체를 정규화한 뒤 type=result 탐색
│  │         또는 --output-format stream-json (JSONL; wire shape 재검증 미수행)
│  └─ NO → 기본 text 출력
│
├─ harness 인벤토리를 검증하고 싶다면?
│  └─ --output-format json → init 이벤트 파싱
│     → references/harness-testing.md T1 참조
│
├─ 원격 머신에서 실행해야 한다면?
│  └─ echo "prompt" | ssh host 'claude -p ...'
│     ⚠️ alias 사용 불가, stdin pipe 필수
│     → references/patterns.md 패턴 5 참조
│
├─ 이전 세션을 이어가야 한다면?
│  └─ --resume SESSION_ID
│     → references/patterns.md 패턴 4 참조
│
└─ 결과를 파일에 저장해야 한다면?
   └─ shell redirect: > result.txt
      ⚠️ --output-file / -o 플래그 존재하지 않음
```

## 빠른 참조

| 상황 | 명령 |
|------|------|
| 단순 질의 | `echo "prompt" \| claude -p` |
| 도구 실행 | `echo "prompt" \| claude -p --dangerously-skip-permissions` |
| harness 인벤토리 | `echo "ok" \| claude -p --output-format json` → init 파싱 |
| 세션 이어가기 | `echo "prompt" \| claude -p --resume SESSION_ID` |
| 원격 실행 | `echo "prompt" \| ssh host 'claude -p ...'` |
| 결과 저장 | `echo "prompt" \| claude -p > result.txt` |
| 모델 선택 | `echo "prompt" \| claude -p --model sonnet` |
| 시스템 프롬프트 추가 | `echo "prompt" \| claude -p --append-system-prompt "..."` |

## 핵심 Gotchas

1. `<values...>` variadic flag 뒤 인라인 프롬프트가 flag 값으로 소비됨: `--allowed-tools`, `--disallowed-tools` 등은 stdin으로 prompt 전달
2. `--max-turns 1`은 도구 실행 불가 — 최소 2턴 필요 (v2.1.202 실측; 2.1.206 재검증 미수행 — help에는 없지만 parser 수용 확인)
3. exit code나 `subtype=success` 하나만으로 성공 판정 금지: exit + subtype/is_error + 기대 산출물 + 진척 delta 확인
4. `--cwd`, `--output-file` 플래그 없음: `cd dir && claude -p`, shell redirect `> file` 사용
5. SSH alias 미로드: non-login shell에서 `c` alias 사용 불가 → `claude` full path 필수
6. `--append-system-prompt`는 append — 기존 시스템 프롬프트를 override하지 못함 (v2.1.202 실측; 2.1.206 재검증 미수행)
7. `--tools ""`로 빌트인을 비활성화해도 MCP는 남음 — MCP 비활성화는 별도 조치 필요 (v2.1.202 실측; 2.1.206 재검증 미수행)
8. 플러그인 스킬 인식은 설치 시점에 고정 — 캐시 수정·symlink·브랜치 변경 대신 stdin 주입 또는 재설치 (v2.1.202 실측; 2.1.206 재검증 미수행)
9. 커스텀 환경변수는 명시적으로 전달 — `.env`는 자동 로드되지 않으므로 `VAR=val claude -p` 사용 (v2.1.202 실측; 2.1.206 재검증 미수행)
10. 대용량 stdin은 정상 동작 — 극단적 상한은 미확인하므로 프로덕션에서는 청킹 병행 (v2.1.202 실측; 2.1.206 재검증 미수행)

전체 목록: [references/gotchas.md](references/gotchas.md)

## 셸 transport 계약

- stdout, stderr, 업무 산출물을 분리 보관한다. JSON parser 앞 `2>&1`은 stderr를 섞어 파싱을 깨뜨린다.
- pipeline은 `set -o pipefail`을 사용한다. zsh에서 Claude 자체 exit가 필요하면 pipeline 직후
  `claude_rc=$pipestatus[2]`로 보존한다.
- `| head`, `| tail`, 뒤이은 `; echo $?`는 원래 exit를 가릴 수 있으므로 판정 경로에서 제외한다.

## 성공 계약

`claude -p --output-format json` 완료는 다음 조건을 모두 만족해야 한다.

1. process exit가 0이다.
2. `type=result` 이벤트가 있고 `subtype=success`, `is_error=false`다.
3. 파일 생성을 요구한 작업은 `test -s "$RESULT"`를 통과하고 기대 완료 표식이 있다.
4. 반복 pass는 직전 결과 대비 새 finding·수정·판정 같은 진척 delta가 있다.

2.1.206 성공 경로는 4-event 배열과 `result/success`, `is_error:false`, exit 0을 냈다. 반대로
auth 실패 경로는 `subtype:success`, `is_error:true`, exit 1도 가능했다. 산출물 0개인데 success인
실전 사례가 있으므로 진척 없는 pass가 연속되면 circuit breaker로 중단한다. child에게 같은
collector/fan-out을 다시 생성시키지 않는다.

## SSH 크로스머신 요약

```bash
# ✅ 유일한 안정 패턴: stdin pipe
echo "hostname 실행 결과만 출력해" | ssh minipc 'claude -p --dangerously-skip-permissions'

# ❌ 피해야 할 패턴: 3중 중첩 quote
ssh minipc 'zsh -li -c "c -p \"...\""'  # → unmatched quote
```

- SSH non-login shell에서 alias 미로드 → `claude` full path 필수
- 3중 중첩 quote 지옥 → 파일 기반 stdin pipe가 유일한 안정 패턴
- 무출력 약 10분 뒤 완료된 실측이 있다. 무출력만으로 중단, 프로세스 생존만으로 정상이라 판정하지 않는다.
- outer timeout과 `ServerAliveInterval`을 적용하고 종료 뒤 `test -s`로 산출물을 확인한다.

상세: [references/patterns.md](references/patterns.md) 패턴 5

## Harness 셀프테스트 요약

`--output-format json`의 init 이벤트로 harness 구성요소를 자동 검증한다.

| 테스트 | 목적 | 비용 |
|--------|------|------|
| T1 | init 인벤토리 (skills/tools/MCP/plugins 수) | ~$0.07 |
| T2 | 스킬 트리거 spot check | ~$0 (T1 재사용) |
| T3 | hooks 파일 존재/실행 가능 여부 | $0 |
| T4 | MCP 서버 init 등록 확인 | ~$0 (T1 재사용) |
| T5 | 권한 모델 (차단/허용) | ~$0.14 |
| T6 | SSH 크로스머신 실행 | ~$0.07 |
| T7 | 세션 체이닝 (`--resume`) | ~$0.14 |
| T8 | 동시 실행 안정성 | ~$0.14 |

상세 코드 및 판정 로직: [references/harness-testing.md](references/harness-testing.md)
비용 수치는 재검증 미수행 (v2.1.202 기준 서술 유지).

## 하지 말아야 할 패턴

| 금지 패턴 | 발생 에러 | 올바른 대안 |
|-----------|----------|------------|
| `--allowed-tools "Bash" "prompt"` | 프롬프트가 도구 이름으로 파싱 | stdin pipe 사용 |
| `--dangerously-skip-permissions` + `--allowed-tools` | allowlist 구조적 무효 | 제한 필요: allowed-tools + stdin / 제한 불필요: skip 단독 |
| `--max-turns 1` + 도구 실행 기대 | Reached max turns | `--max-turns 2` 이상 (v2.1.202 실측) |
| exit 또는 `subtype=success` 하나로 성공 판정 | 무산출물·auth 실패 오판 | 성공 계약 네 조건 확인 |
| JSON parser 앞 `2>&1` | stderr 혼입으로 파싱 실패 | stdout/stderr/산출물 분리 |
| 판정 pipeline 끝의 `head`/`tail`/`; echo $?` | 원 exit 은폐 | `pipefail`과 즉시 exit 보존 |
| SSH에서 `c -p` alias | command not found | `claude -p` full path |
| 3중 중첩 quote (SSH) | unmatched quote | stdin pipe 패턴 |
| `--verbose`/`--debug`로 디버그 | stderr 출력 없음 | `--debug-file` 사용 |
| 플러그인 캐시 디렉토리 수동 수정 | 인식 안 됨 (설치 시점 인덱싱) | SKILL.md stdin 주입 (패턴 9) |
| child가 같은 collector를 다시 생성 | 무한 자기증식 | 오케스트레이션은 부모 1계층에서만 수행 |

## 참조

- 숨겨진 동작: [references/gotchas.md](references/gotchas.md)
- 사용 패턴: [references/patterns.md](references/patterns.md)
- 셀프테스트 T1~T8: [references/harness-testing.md](references/harness-testing.md)
- 플래그 호환성 매트릭스: [references/flag-matrix.md](references/flag-matrix.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
help는 공개 surface의 SSOT다. help에 없는 hidden flag의 제거 여부는 실행 smoke로만 판정한다.
