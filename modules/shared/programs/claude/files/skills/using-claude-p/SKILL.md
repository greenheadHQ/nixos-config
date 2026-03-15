---
name: using-claude-p
description: |
  Claude Code non-interactive (-p/--print) 모드의 프로그래밍적 사용법:
  harness 셀프테스트, SSH 크로스머신 패턴, 입출력 형식, 권한 모델, 숨겨진 동작.
  NOT for Codex CLI (use using-codex-exec).
  NOT for Claude Code hooks/plugins/settings 설정 (use configuring-claude-code).
  NOT for codex harness 동기화 (use syncing-codex-harness).
  Triggers: "claude -p", "claude --print", "비대화형 claude", "headless",
  "harness test", "harness 테스트", "claude -p 테스트", "init event",
  "셀프테스트", "self-test", "c -p", "프로그래밍적 실행",
  "non-interactive claude", "headless mode", "Agent SDK CLI".
---

# Claude Code 비대화형 모드 (`claude -p`) 사용

Claude Code의 `-p`/`--print` 모드(비대화형/headless)를 정확하게 사용하는 절차를 다룬다.

## 작성 기준

- 확인 날짜: **2026-03-15**
- 확인 버전: **Claude Code v2.1.76**
- 재검증: `claude --version && claude -p --help`

## 범위

| 포함 | 제외 |
|------|------|
| `claude -p` 비대화형 실행 | 대화형 TUI 사용법 |
| `--output-format json` 파싱 | Claude Code hooks/plugins 설정 → `configuring-claude-code` |
| harness 셀프테스트 (T1~T8) | Codex CLI 실행 → `using-codex-exec` |
| SSH 경유 크로스머신 실행 | harness 동기화 → `syncing-codex-harness` |
| 숨겨진 동작 36건 | Python/TS SDK (별도 스킬 분리 대상) |
| 세션 체이닝 (`--resume`) | |

## 의사결정 트리

```
claude -p 실행이 필요한가?
│
├─ 도구 실행이 필요한가?
│  ├─ YES → --dangerously-skip-permissions 추가
│  │         도구를 제한할 필요가 있나?
│  │         ├─ YES → --allowed-tools "Bash,Read" (stdin 필수!)
│  │         └─ NO → 그대로 실행
│  └─ NO → 기본 실행 (권한 플래그 불필요)
│
├─ 출력을 프로그래밍적으로 파싱할 필요가 있나?
│  ├─ YES → --output-format json (JSON 배열)
│  │         또는 --output-format stream-json (JSONL)
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

1. **`--allowedTools` + 인라인 프롬프트 = 버그**: 인라인 프롬프트가 도구 이름으로 먹힘 → stdin 필수
2. **`--max-turns 1`은 도구 실행 불가**: 도구 사용에 최소 2턴 필요 (호출 + 결과 수신)
3. **도구 거부/예산 초과도 exit code 0**: 실패를 감지하려면 `--output-format json`의 result subtype 확인 필수
4. **`--cwd`, `--output-file` 플래그 없음**: `cd dir && claude -p`, shell redirect `> file` 사용
5. **SSH alias 미로드**: non-login shell에서 `c` alias 사용 불가 → `claude` full path 필수
6. **`--append-system-prompt`는 append**: 기존 시스템 프롬프트를 override하지 못함
7. **`--tools ""`로 빌트인 비활성화해도 MCP 남아있음**: MCP도 비활성화하려면 별도 조치 필요

전체 36건: [references/gotchas.md](references/gotchas.md)

## SSH 크로스머신 요약

```bash
# ✅ 유일한 안정 패턴: stdin pipe
echo "hostname 실행 결과만 출력해" | ssh minipc 'claude -p --dangerously-skip-permissions'

# ❌ 피해야 할 패턴: 3중 중첩 quote
ssh minipc 'zsh -li -c "c -p \"...\""'  # → unmatched quote
```

- SSH non-login shell에서 alias 미로드 → `claude` full path 필수
- 3중 중첩 quote 지옥 → 파일 기반 stdin pipe가 유일한 안정 패턴
- MiniPC sshd 180초 무응답 시 연결 해제 → 장시간 실행 시 `ServerAliveInterval` 추가

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

## 하지 말아야 할 패턴

| 금지 패턴 | 발생 에러 | 올바른 대안 |
|-----------|----------|------------|
| `--allowedTools "Bash" "prompt"` | 프롬프트가 도구 이름으로 파싱 | stdin pipe 사용 |
| `--max-turns 1` + 도구 실행 기대 | Reached max turns | `--max-turns 2` 이상 |
| exit code로 실패 판정 | 대부분 에러도 exit 0 | `--output-format json` subtype 확인 |
| SSH에서 `c -p` alias | command not found | `claude -p` full path |
| 3중 중첩 quote (SSH) | unmatched quote | stdin pipe 패턴 |
| `--verbose`/`--debug`로 디버그 | stderr 출력 없음 | `--debug-file` 사용 |

## 참조

- **숨겨진 동작 36건**: [references/gotchas.md](references/gotchas.md)
- **사용 패턴 8종**: [references/patterns.md](references/patterns.md)
- **셀프테스트 T1~T8**: [references/harness-testing.md](references/harness-testing.md)
- **플래그 호환성 매트릭스**: [references/flag-matrix.md](references/flag-matrix.md)

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
`claude -p --help` 출력이 이 문서보다 항상 우선하는 진실 원천이다.
