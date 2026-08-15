---
name: using-claude-p
description: >-
  Run Claude Code non-interactively with claude -p for headless automation, JSON parsing, or SSH
  execution. Use when requests mention `claude -p`/`비대화형 claude`, or before you launch, probe,
  or verify a headless claude subprocess yourself. Use using-codex-exec for Codex subprocesses.
---

# Claude Code 비대화형 모드 (`claude -p`) 사용

상세 flag·gotcha의 SSOT는 [flag-matrix.md](references/flag-matrix.md)와
[gotchas.md](references/gotchas.md)이며, 본문은 선택 기준과 성공 계약만 요약한다.
설정 키워드 검색으로 시작하지 말고 의사결정 트리와 성공 계약부터 읽는다 — 이미 문서화된
사실을 시행착오로 재발견한 세션이 다수였다.

## 작성 기준

- 확인 날짜: 2026-07-10
- 확인 버전: Claude Code v2.1.206
- 재검증: `claude --version && claude --help && claude -p --help`
- 개별 항목에 `재확인: <날짜>, <버전>` 스탬프가 붙어 있으면 그 스탬프가 위 헤더보다 우선한다
  (헤더는 문서 전체를 일괄 재확인한 시점이고, 개별 스탬프는 그 항목만 최신 버전으로 재실측한
  시점이다). 2.1.233 런타임 관측 항목의 재검증 명령은
  `echo "ok" | claude -p --model haiku --output-format json`이며, 각 항목이 요구하는 추가
  플래그는 해당 항목에 함께 적는다.
- 버전 warn 시 최소 재검증 세트: 위 help diff + 실행 smoke 3종 (① json 성공 경로 wire shape
  ② 성공 계약 판정식 ③ help diff에서 변경이 의심되는 개별 항목 — 각 항목이 명시한 호출 형태
  그대로). 전면 재확인 없이 헤더만 올리지 않는다.

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
│  │    ├─ YES, 정밀 allowlist → --allowed-tools "Bash,Read" (stdin 필수!)
│  │    │         ⚠️ --dangerously-skip-permissions와 함께 쓰면 제한 무효
│  │    │         ⚠️ Bash 패턴은 따옴표·공백 민감 (gotchas #36·#46) — 스킬 실행엔 부적합할 수 있음
│  │    ├─ YES, 위험 도구만 차단 → --permission-mode dontAsk + deny 규칙 (hooks·deny 존중)
│  │    │         또는 --dangerously-skip-permissions + --disallowedTools Write,Edit
│  │    └─ NO → --dangerously-skip-permissions 추가 (전면 우회 아님 — carve-out은 gotchas #43)
│  └─ NO → 기본 실행 (권한 플래그 불필요)
│
├─ 출력을 프로그래밍적으로 파싱할 필요가 있나?
│  ├─ YES → --output-format json (가변 길이 이벤트 스트림 — 이벤트 수는 런마다 다름, 2.1.233 실측)
│  │         배열/객체를 정규화한 뒤 type=result 탐색 (후행 비-JSON 라인 내성 필수)
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
10. piped stdin 상한은 10MB (공식 headless 문서 계약) — 발사 전 `wc -c` 게이트로 자르고, 초과분은 파일에 쓰고 경로를 프롬프트에서 참조한다 (gotchas #40)

전체 목록: [references/gotchas.md](references/gotchas.md)

## 셸 transport 계약

- stdout, stderr, 업무 산출물을 분리 보관한다. JSON parser 앞 `2>&1`은 stderr를 섞어 파싱을 깨뜨린다.
- pipeline은 `set -o pipefail`을 사용한다. zsh에서 Claude 자체 exit가 필요하면 pipeline 직후
  `claude_rc=$pipestatus[2]`로 보존한다.
- `| head`, `| tail`, 뒤이은 `; echo $?`는 원래 exit를 가릴 수 있으므로 판정 경로에서 제외한다.

## 호출 상한 (Bash tool 경유)

Claude Code 하네스의 Bash tool로 `claude -p`를 발사할 때는 하네스 상한이 실질 상한이다.
수치·계약의 SoT는 [using-codex-exec SKILL.md "foreground/background 상한 불일치"](../using-codex-exec/SKILL.md#foregroundbackground-상한-불일치-호출-방식-계약) 절이다
(그 절이 명시하듯 `claude -p` headless에 공통 적용). 이 절은 수치를 복제하지 않는다 — 규칙만 적는다.

- foreground 호출은 하네스 timeout이 wrapper·SSH 등 안쪽 예산보다 먼저 발화한다. timeout
  파라미터에 상한 초과값을 줘도 거부되지 않지만 실효 상한은 하네스 최대치로 클램프된다
  (2.1.233 실측: 660초 작업에 `timeout: 900000` 지정 → 600초에 발화).
- 상한 도달의 처리는 버전에 따라 다르다 — 2.1.233 실측에서는 프로세스를 죽이지 않고
  `Command did not complete within its 600s timeout and was moved to the background`로
  background 전환했고, 작업은 660초를 완주해 exit 0으로 끝났다 (구 버전 2.1.220 관측은
  `Exit code 143 / Command timed out`으로 종료). 어느 쪽이든 foreground 응답은 그 시점에
  끊기므로, 결과는 stdout이 아니라 파일 또는 완료 알림의 output 경로에서 회수한다.
- 동일 응답에서 여러 foreground Bash 호출을 발사해도 병렬이 아니라 직렬 실행된다
  (2.1.233 실측: 3초 작업 4개가 0.0→3.0, 3.1→6.1, 6.2→9.2, 9.3→12.3초로 순차). fan-out
  예산은 합산해야 하며, 실제 병렬은 `run_in_background: true`뿐이다.
- 수 분 이상 걸릴 수 있는 호출은 Bash tool `run_in_background: true`로 발사한다. 완료 알림의
  exit code는 claude가 아니라 래핑 셸의 최종 rc다 — `rc 캡처 → .rc 파일 영속화 → exit $rc`로
  끝낸다 (using-codex-exec SKILL.md "background 발사의 rc 계약"과 동일 규약; 꼬리 echo/cat을 두면
  전건 실패도 completed로 통지된다).
- foreground `sleep`은 하네스가 차단한다 (`Blocked: sleep ...` 실측) — 대기는 Monitor
  until-loop 또는 run_in_background 완료 알림으로 한다.
- Bash tool 호출 사이에 셸 변수·함수·`trap EXIT`는 소멸한다 — 경로·상태는 파일로 영속화한다.
- 하네스 timeout으로 잘린 호출은 명령 말미의 in-band 계약 검사(`_EC=$?; ...` 후속 라인)까지
  함께 사라진다 — 판정은 별도 호출(out-of-band)로 재확인한다.
- 용어 구분 3종: CLI 플래그 `--background`/`--bg`(background agent 시작) ≠ Bash tool
  `run_in_background` 파라미터 ≠ 하네스의 foreground→background 자동 전환(foreground 상한
  도달이 트리거 — 위 실측). 자동 전환되면 stdout 직수신 전제가 깨지므로 결과는 항상 파일로
  받는다. 전환됐다고 실패한 것은 아니다 — 작업은 계속되고 완료 알림이 온다.

## 성공 계약

`claude -p --output-format json` 완료는 다음 조건을 모두 만족해야 한다.

1. process exit가 0이다.
2. `type=result` 이벤트가 있고 `subtype=success`, `is_error=false`다. 보조 축 (2.1.233 실측 —
   같은 result 이벤트에서 무료로 얻는다): `terminal_reason`이 `completed`가 아니면 비정상 종료,
   `permission_denials`가 비어 있지 않으면 exit 0이어도 도구가 차단된 것이다 (gotchas #3의
   프로그래밍적 탐지 — "도구 거부는 exit로 못 잡는다" 갭을 이 필드가 메운다).
3. 파일 생성을 요구한 작업은 `test -s "$RESULT"`를 통과하고 기대 완료 표식이 있다 —
   단 이 판정은 종료 후에만 한다. json 출력은 완료 시 일괄 기록이라 실행 중 0바이트는
   실패 신호가 아니다 (gotchas #48).
4. 반복 pass는 직전 결과 대비 새 finding·수정·판정 같은 진척 delta가 있다.

성공 경로의 이벤트 스트림은 가변 길이다 (2.1.233 실측: 같은 버전·같은 플래그·같은 모델에서도
`thinking_tokens` 이벤트 수에 따라 런마다 다름 — 특정 이벤트 개수를 기대하는 파서 금지).
help는 `json (single result)`, 공식 문서는 result 필드를 가진 단일 객체를 예시하지만 실측
런타임은 top-level 배열이다 — 어느 쪽도 가정하지 말고 배열/객체를 정규화한 뒤 `type=result`를
찾는 파서가 유일 경로다. stdout 말미에 비-JSON 경고 라인이 간헐 혼입되므로(MCP 구성 의존,
2.1.233 실측) 파서는 첫 JSON 문서만 취하되, 그래도 파싱이 실패하면 raw를 조용히 흘리지 말고
non-zero로 죽어야 한다. 반대로 auth 실패 경로는 `subtype:success`, `is_error:true`, exit 1도
가능했다. 산출물 0개인데 success인 실전 사례가 있으므로 진척 없는 pass가 연속되면 circuit
breaker로 중단한다. child에게 같은 collector/fan-out을 다시 생성시키지 않는다.

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
| T2a | 스킬 등록 spot check | ~$0 (T1 재사용) |
| T2b | 스킬 발동 회귀 (positive/negative 대조) | 호출 2회 (haiku) |
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
| `--max-turns 1` + 도구 실행 기대 | exit 1 + `subtype=error_max_turns` + `is_error:true` (2.1.233 실측 — 메시지는 stderr가 아니라 stdout/`result.errors[]`) | `--max-turns 2` 이상 |
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
