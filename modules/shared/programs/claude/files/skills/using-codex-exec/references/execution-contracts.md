# 실행·결과 회수·격리 계약

## 셸 transport 계약

- stdout, stderr, `-o` 결과를 서로 다른 파일에 저장한다. JSON/JSONL parser 앞에서 `2>&1`로
  stderr를 합치면 파싱이 깨진다.
- pipeline에는 `set -o pipefail`을 적용한다. zsh에서 Codex 자체 exit가 필요하면 pipeline 직후
  `codex_rc=$pipestatus[2]`로 보존한다.
- 좌측 명령(`cat` 등)의 실패까지 판정에 포함하려면 pipeline 직후 배열을 먼저 스냅샷한다
  (`pipe_rcs=("${PIPESTATUS[@]}")`; zsh는 `("${pipestatus[@]}")`) — `$?`나 개별 원소를 나중에
  읽으면 그 사이 명령이 PIPESTATUS를 리셋한다.
- `| head`, `| tail`, 뒤이은 `; echo $?`는 원래 exit를 가릴 수 있으므로 판정 경로에 두지 않는다.

```zsh
set -o pipefail
cat prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o result.md - >stdout.log 2>stderr.log
codex_rc=$pipestatus[2]
```

## 성공 계약

프로세스 exit만으로 업무 성공을 판정하지 않는다. 실패 판정의 정본은 ① rc → ② 결과 파일
순서이며, stderr는 실패 판정 입력이 아니라 원인 분류 입력이다 (조건 3; 재확인: 2026-08-15, 0.147.0).

1. wrapper/CLI exit가 0이다.
2. 기대 산출물이 존재하고 비어 있지 않으며(`test -s "$RESULT"`) 내용이 형식 계약을 만족한다:
   - 완료 표식을 요구한 작업은 결과 본문에 그 표식이 있다 (프롬프트에서 마지막 줄 단일 판정 토큰을
     강제하면 판정이 단순해진다).
   - 첫 줄이 `VIOLATION` 등 자기신고 실패 선언이면 실패다 — read-only 리뷰어가 sandbox 거부를
     본문으로 보고해 exit 0 + non-empty를 통과한 실측 사례가 있다.
   - JSON을 요구한 작업은 코드 펜스 제거 후 `jq -e` 파싱과 필수 키 존재까지 확인한다. `-o` 파일에
     ` ```json ` 펜스·대화체 서문이 혼입되거나, 스키마 정의(`$schema` 키)가 인스턴스 대신 반환된
     실측 사례가 있다. "펜스 없이"라는 프롬프트 지시는 비결정적이라 판정식의 대체재가 아니다.
   - 결과 회수 경로는 `-o` 파일 또는 rollout의 `task_complete.last_agent_message`로 한정한다.
     stdout의 첫 유효 JSON을 취하는 파싱은 금지 — 도구 호출 전 조기 `{"issues":[]}` 선방출 실측이 있다.
   - 결과 파일 바이트 수 하한 휴리스틱은 금지한다 — 정상 판정 응답이 13~19바이트일 수 있다.
3. stderr는 rc 또는 조건 2가 실패했을 때 원인 분류에만 쓴다. `! grep -q "ERROR:"`를 1차 실패
   판정으로 쓰지 마라 (0.147.0 실측): stderr에는 프롬프트 전문 에코·최종 메시지 사본·무해
   tracing `ERROR` 라인이 정상 실행에도 남아 상시 오탐이고, 반대로 timeout(wrapper rc 124/137로만
   식별됨 — wrapper stderr에 `ERROR:` 0건)·소문자 `Error:` 계열(config/인자 오류)·`Error` 토큰조차
   없는 평문 pre-flight 오류(trusted directory 등)는 원리적으로 걸리지 않는다. 리터럴 `ERROR:`가
   생존하는 표면은 턴/스트림 오류(미지원 모델 등) 1개 축뿐이다. 분류 절차는
   [known-issues.md §0-1](known-issues.md#0-1-stderr-원인-분류-절차)를 따른다.
4. 반복 라운드라면 직전 결과 대비 새 finding·수정·판정 같은 진척 delta가 있다.

진척 없는 pass가 연속되면 circuit breaker로 중단하고 같은 호출을 증식시키지 않는다.
fan-out은 패턴 8 스모크를 한 번 통과한 뒤 시작한다.

| 분류 | 신호 | 처리 |
|------|------|------|
| wrapper 사전 검증 실패 / PATH 미해석 | `command -v codex` 실패 또는 exit 127 | wrapper 127은 PATH 외에 invalid env 값·정본 `CODEX_EXEC_*` 변수명 near-miss도 포함하므로 stderr를 먼저 읽는다. 이후 `command -v codex` → `codex-exec-supervised --check` → 확인된 절대경로 순으로 진단. 설치 부재로 단정하지 않는다. |
| 부모 sandbox denial | session/config 파일 쓰기 거부, nested 실행 | 소유권 변경 없이 [known-issues.md §18](known-issues.md#18-중첩-codex-session-파일-쓰기-거부와-sudo-chown-오진)로 분기 |
| timeout | rc 124 (SIGTERM 단계) — timeout 확정 신호 | rc 124는 실패가 아니라 budget 부족 신호다 — 동일 budget 재시도는 금지하고, budget 상향 후 fresh retry 1회만 허용. stderr·프로세스 정리를 먼저 확인 |
| rc 137 (SIGKILL) — 원인 다중 | wrapper `--kill-after` 승급 / codex 자신의 137 passthrough / 외부 SIGKILL이 모두 같은 값을 낸다 | 137 단독으로 timeout이라 단정하지 않는다. (code, signal) + wrapper budget 도달 여부(경과 시간)와 stderr를 함께 본다. usage limit hang이 외부 SIGKILL로 끝난 경우도 137이므로 아래 usage limit 행과 교차 확인 |
| usage limit | (a) 즉시형: stderr `hit your usage limit ... try again at <시각>` (b) hang형: 내부 재시도로 무진척, 외부 SIGKILL 시 exit null/137로 위장 | 신규 세션 재시도는 무익하므로 fail-fast. 이미 진행 중인 세션은 계속될 수 있음. 판정은 exit code 단독이 아니라 (code, signal) + stderr 패턴 매치로 — stderr tail 바이트로 진단하면 프롬프트 에코가 찍혀 원인 불명이 된다 (실측) |
| unsupported model | metadata warning 또는 unsupported error | `-m`을 제거하고 config 기본 모델로 제한된 fresh retry |
| stream 실패 | stderr `stream disconnected before completion` | 일시 오류 — retryable. 수만 토큰 소모 후 `-o` 미생성으로 끝날 수 있으며, 동일 파라미터 재실행이 성공한 실측(4/4)이 있다 (2026-08-15, 0.147.0) |
| model at capacity | stderr `Selected model is at capacity` | 모델측 혼잡 — 시간차 재시도 또는 다른 모델. usage limit과 다른 축이므로 fail-fast로 뭉개지 않는다 |
| TLS trust store | stderr `no native root CA certificates found` + `invalid peer certificate: UnknownIssuer` + `Reconnecting... N/5` | exit 0으로 끝난다 — 아래 "exit 0 + 산출물 없음"의 하위 원인. 환경(cert store) 수정 전 재시도 무익. `Reconnecting` 로그는 자격증명 부재 401 반복(upstream #30514, ~20초 후 종료)과 육안 구분이 안 되니 stderr 본문으로 가른다 |
| exit 0 + 산출물 없음 | `test -s` 실패 | 실패로 처리하고 stderr·라우팅·resume session id를 조사. TLS trust store 실패가 이 형태로 나타난다 (위 행) |

non-retryable (재시도 루프 진입 금지): `Not inside a trusted directory ...`, `unexpected argument`,
clap 상호 배타 인자 오류 — 결정론적 인자/환경 오류인데 rc 1이라 일반 실패와 구분되지 않으므로
stderr 문자열로 식별해 즉시 교정한다. 같은 명령 재시도는 같은 오류만 반복한다.

### background 발사의 rc 계약

Bash tool `run_in_background` 완료 알림의 exit code는 codex가 아니라 래핑 셸의 최종 rc다
(2026-08-15, Claude Code 2.1.233 하네스 A/B 실측). 발사 명령 말미에 echo·cat 같은 꼬리 명령을
두면 전건 실패도 `completed (exit code 0)`으로 통지된다 — 독립 10세션의 background 발사 317건 중
86%가 이 형태였고, codex 전건 실패(결과 파일 0건)를 성공 알림으로 받은 사고가 실재한다.
꼬리 `echo "EXIT=$?"`는 관측성조차 제공하지 못한다(알림에서 값이 회수된 사례 0건). 표준 발사 형태:

```zsh
cat "$PROMPT" | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o "$OUT" - > "$OUT.stdout" 2> "$OUT.stderr"
pipe_rcs=("${pipestatus[@]}")  # 배열을 먼저 스냅샷한다 — 다음 명령이 리셋한다
rc="${pipe_rcs[2]}"            # codex의 rc (zsh 1-base). 파이프 없는 발사는 rc=$?
[ -n "$rc" ] && [ -n "${pipe_rcs[1]}" ] || { echo "rc 캡처 실패 — 셸/배열 불일치" >&2; exit 1; }
[ "${pipe_rcs[1]}" = "0" ] || rc="${pipe_rcs[1]}"   # 좌측 cat 실패도 rc에 반영 (= 문자열 비교 — 빈 값이면 위 guard가 먼저 잡는다)
printf '%s' "$rc" > "$OUT.rc"  # rc 영속화 — 알림 유실 대비·다수 병렬 배리어의 정본
exit $rc                       # 하네스 완료 알림에 codex rc가 실리게 한다
```

- Bash tool 셸은 zsh다. bash에서 재사용하려면 `pipestatus` → `PIPESTATUS`, 인덱스 1-base →
  0-base로 함께 바꾼다 — 한쪽만 바꾸면 rc가 빈 값이 되어 `.rc`가 비고 계약이 무력화된다
  (위 `[ -n "$rc" ]` 가드가 그 상태를 fail-closed로 잡는다).
- `.rc` 파일 부재 자체를 실패로 취급한다 — guard 조기 exit 경로가 은폐되지 않는다.
- 좌측 `cat` 실패(프롬프트 파일 부재·손상)는 codex가 빈 stdin으로 exit 0을 낼 수 있어 위
  스냅샷 없이는 성공으로 오판된다 — 셸 transport 계약의 배열 스냅샷 규칙과 동일 축이다.

### foreground/background 상한 불일치 (호출 방식 계약)

wrapper 기본 timeout 1800초는 호출 방식과 무관한 wrapper의 운영 budget이지만, Claude Code 하네스의 Bash tool을 경유하는 foreground 호출에서는 안쪽 예산이 하네스 상한보다 길 때 이 budget에 도달하지 못한다 — 상한은 세션 유형이 아니라 하네스 속성이라 대화형 세션과 `claude -p` headless에 공통 적용되며, Bash tool의 foreground 대기 상한은 기본 120초, `timeout` 파라미터 명시 시 최대 600초(10분)다. 초과값을 줘도 거부되지 않고 600초로 클램프된다 (재확인: 2026-08-15, Claude Code 2.1.233 — 660초 작업에 `timeout: 900000` 지정 → 600초에 발화). 안쪽 timeout(wrapper·SSH)이 하네스 상한보다 짧으면 당연히 그쪽이 먼저 발화한다.

상한 도달 시 처리는 하네스 버전에 따라 다르므로 결과 회수 계약도 갈린다:

| 하네스 동작 | 관측 | 결과 회수 |
|---|---|---|
| background 자동 전환 | 2.1.233 실측 — `Command did not complete within its 600s timeout and was moved to the background`. 프로세스는 살아 660초를 완주하고 exit 0 | 작업이 계속되므로 완료 알림의 output 경로 또는 `-o` 결과 파일에서 회수 |
| 프로세스 종료 | 2.1.220 관측 — `Exit code 143 / Command timed out` (2026-07-10 실사례: Arbiter foreground 실행이 10분에 잘리고 background 재실행으로 8분 34초 만에 성공) | 완료 알림이 오지 않는다. 종료 시점까지 이미 파일로 영속화된 산출물만 회수 가능하므로 중간 결과를 파일에 흘려두지 않았다면 유실 |

재현: 하네스 상한을 넘는 작업(예: `python3 -c "import time; time.sleep(660)"`)을 foreground로, Bash tool `timeout` 파라미터에 상한 초과값(예: 900000)을 지정해 발사하고 어느 쪽 동작이 나오는지 관측한다 (모델 호출 0).

수 분 이상 걸릴 수 있는 programmatic 호출은 처음부터 background로 실행하고, foreground가 꼭 필요하면 Bash tool `timeout` 파라미터를 반드시 명시하되 wrapper budget이 아니라 하네스 상한이 실질 상한임을 전제한다. 어느 경우든 결과는 stdout이 아니라 파일로 받는다 — 두 동작 모두 foreground 응답은 그 시점에 끊긴다. run-da의 role별·하네스별 발사 방식은 run-da 스킬 `references/arbiter-scaling.md`의 실행 계약이 소유하며, 본 절은 그 계약이 참조하는 하네스 상한 사실의 정본이다.

## Gotchas

1. `--search`는 exec에서 미동작: `error: unexpected argument '--search' found` (0.147.0 동일). web search 도구는 config·플래그 없이도 exec에 제공되어 실제 동작함을 실측 (2026-08-15, 0.147.0 라이브 1회 + rollout 교차확인). 웹검색은 sandbox tier와 무관한 서버측 별개 경로다 — `-s read-only`로 셸 네트워크를 차단해도 web_search는 동작하므로 세션 격리로 오해하지 말 것. 질의는 외부로 나가므로 fail-closed 규칙을 적용한다: 저장소·서비스명, 파일 경로, private 심볼명, 시크릿, 개인정보를 제거한 일반화 질의만 허용하고, 그렇게 일반화할 수 없는 질문이면 사용자 승인 없이 web_search를 호출하지 않는다 (프롬프트에 "필요한 외부 정보는 호출자가 미리 캡처해 주입"을 명시하는 편이 안전하다).
2. `--full-auto`는 0.147.0에서 완전 제거 — 전 서브커맨드(exec/review/resume/top-level)에서 rc 2 `unexpected argument`로 즉시 실패한다 (2026-08-15 실측; 변천은 known-issues "버전별 변천"). 과거 세션 로그·문서 예시의 `--full-auto`를 복사하지 마라. 새 호출은 `-s workspace-write`를 사용한다. 명시한 `-s` 값이 `config.toml`의 `sandbox_mode`를 override한다 (2026-07-03, 0.142.5 실측: `-s read-only` 지정 시 config가 `danger-full-access`여도 read-only로 실행됨; 0.144.1 재검증 미수행).
3. CODEX_API_KEY는 exec 전용: interactive TUI와 VS Code extension에서는 무시됨. OPENAI_API_KEY는 auth 체인에 미참여 (TUI prefill 전용). 우선순위: CODEX_API_KEY > ephemeral tokens > auth.json. 재검증 미수행 (0.142.5 기준 서술 유지; 상세: [known-issues.md §17](known-issues.md#17-exec-auth-chain-우선순위와-login-status-한계))
4. 무저장 cwd의 `resume --last`는 두 실패 축이 있다 — (a) exit 0 silent fallback: 오류 대신 새 session id로 조용히 시작 (0.144.1 관측; fallback 로직은 0.147.0에도 잔존 — 도달 불가 provider 실행에서 새 세션 발급 관측). (b) 무출력 hang: 배너 이전 단계에서 무기한 정지, stderr 0바이트 (0.147.0 실측 5/5 — 대형 세션 코퍼스 환경 시그니처, wrapper timeout rc 124가 유일 구제. stderr가 완전히 비므로 stderr 기반 판정은 이 실패를 놓친다). 어느 축이든 처방 동일: `--last` 대신 세션 id 명시, supervised 경로 필수, session id·응답 context로 판정 — session id 대조는 ANSI 제거 후 값을 추출해 문자열 비교한다 ([세션 재개 예제](execution-guide.md#세션-재개) 참조; 평문 `grep -F`는 강제 컬러 환경에서 항상 실패하고, `grep -E`에 값을 직접 넣으면 접두사·메타문자 오탐이 난다).
5. `codex review` (top-level) vs `codex exec review`: 전자는 `-m`, `--json`, `-o`, `--output-schema`, `--ephemeral`, `-s/--sandbox` 등 미지원 (재확인: 2026-07-10, 0.144.1 help). 비대화형 자동화에는 반드시 `codex exec review` 사용
6. Bash tool sandbox에서 `&` + `$!` 미작동: Claude Code의 Bash tool에서 background process PID 캡처(`$!`)가 리터럴 문자열로 반환됨. shell-level 병렬 대신 여러 병렬 Bash tool 호출 + supervised stdin pipe를 사용한다. 이 제약은 Codex 세션의 native subagent 경로에는 적용되지 않는다. 하네스 속성 — Claude Code 축 스탬프: v2.1.202 관측 서술 유지, 재검증 미수행 (codex 버전과 무관하므로 Claude Code 업그레이드 시 재확인; 상세: [known-issues.md](known-issues.md) §11)
7. stdin pipe로 stdin hang 방지: `cat file | env CODEX_PROGRAMMATIC=1 codex-exec-supervised ... -`로 EOF를 보장한다. `Reading additional input...` banner 하나만으로 hang이라 단정하지 말고, banner + 무진척 + 결과 미생성을 함께 확인한다. 상세: [known-issues.md](known-issues.md) §14
8. `-c hooks.*` inline override는 stdin과 독립적으로 hang을 유발한 실측 축이다. programmatic 호출에서 제거하고 [known-issues.md §15](known-issues.md#15-codex-exec-supervised-wrapper로-14-위에-timeout-budget-한계-보강-issue-593)의 supervisor·timeout 계약을 적용한다.
9. codex exec `--json`은 multi-agent spawn/child 이벤트를 노출하지 않는다 (관측성 한계, 0.144.1). `collaboration.spawn_agent`는 실제로 작동해 child를 생성·실행하지만, 공개 `--json`에는 `tool:"wait"` 이벤트만 보이고 그 `receiver_thread_ids`가 `[]`다 — 이를 spawn 실패로 오판하지 마라 (child가 이미 실행됐을 수 있어 재시도 시 중복 실행). 실제 spawn 여부는 `~/.codex/sessions`의 persisted rollout(`spawn_agent`/`sub_agent_activity`/`inter_agent_communication_metadata`)으로 확인한다. 상세·재검증 probe(버전 변화 시 재확인): [known-issues.md §19](known-issues.md#19-codex-exec---json이-multi-agent-spawnchild-이벤트를-노출하지-않음-관측성-한계)
10. `Not inside a trusted directory and --skip-git-repo-check was not specified.` — git worktree 밖에서 실행하면 rc 1 + 이 문구로 모델 호출 전 즉사한다 (토큰 0, ~1초; 2026-08-15, 0.147.0 실측). fan-out 전멸의 최다 단일 원인 중 하나 (독립 6세션 재현). 트리거 축 4개: ① 비-git cwd ② `-C <비-git scratch>` (판정 대상은 셸 cwd가 아니라 `-C` 값) ③ `resume` (게이트가 세션 조회보다 먼저 발화, 초기 exec의 플래그 비승계) ④ `review --uncommitted` 등 scope 지정 시 (단 review에는 `-C`가 없다). 에러 문구와 달리 판정 기준은 config `trust_level`이 아니라 git worktree 내부 여부 단일 조건이다 — `trust_level="trusted"` 등재로는 통과하지 못하고, 신뢰 목록에 없는 생 `git init` 디렉토리는 통과한다 (실측). `--ephemeral`·`--ignore-user-config`로 우회 불가, `--skip-git-repo-check`가 유일 해제. 프리플라이트: `git -C "$dir" rev-parse --is-inside-work-tree` (플래그 과부착은 무해). 상세: [known-issues.md §8](known-issues.md#8-git-저장소-체크-실패), 격리 실행 블록: [references/patterns.md](patterns.md)
11. `codex exec review`의 `--output-schema`는 인자를 받되 무시하는 silent no-op이다 (재확인: 2026-08-15, 0.147.0 실측: 스키마 required 키를 지정해도 rc 0에 결과는 자연어 리뷰 텍스트, `jq -e`로 필수 키 검사 실패, stderr에 스키마 관련 경고 0건). 즉 review 경로에서는 `--output-schema`도 AGENTS.md 형식 지시도 출력 형식을 강제하지 못한다 — 구조화 출력이 필요하면 exec 우회(방법 B)를 쓰고, CI 게이트가 review의 스키마 강제를 신뢰하지 않게 한다.
12. sandbox denial은 rc 0으로 끝난다 (재확인: 2026-08-15, 0.147.0 실측: `-s read-only`에서 쓰기 지시 → 파일 미변경, rc 0, `-o`에는 모델의 자연어 보고). stderr에는 `ERROR codex_core::tools::router: error=patch rejected: writing is blocked by read-only sandbox ...`가 남지만 리터럴 `ERROR:`는 0건이라 구 판정식으로는 미탐이고, rc·결과 파일 검사로도 잡히지 않는다. 완료 표식이나 모델의 자기신고에 의존하지 마라 — 도구 호출이 거부돼도 모델은 표식을 출력할 수 있다. 쓰기를 요구한 작업의 판정은 실행 밖에서 확인하는 결정적 postcondition이어야 한다: 기대 파일의 존재·내용·해시·`git diff --quiet` 중 작업에 맞는 것을 호출자가 직접 검사한다. 보조로 stderr를 볼 때는 ANSI 제거 후 위 tracing 문자열(`error=patch rejected`)을 찾는다.

## 비신뢰 입력 격리 체크리스트 (미검증 — 세션 실측 6건 기반)

`-s read-only`는 trust boundary의 완결이 아니다 — 차단되는 것은 write뿐이고 read는 그대로
허용되므로, 비신뢰 텍스트를 프롬프트에 넣는 서브프로세스가 홈 설정·SSH 키·복호화된 시크릿
경로를 읽어 자유 문자열로 출력할 수 있다. 비신뢰 입력을 다룰 때:

- env는 allowlist로 최소화해 전달한다 (시크릿 리터럴을 명령 인자로 넘기지 않는다 — 프로세스
  목록·로그 노출).
- 임시 non-git cwd + `--skip-git-repo-check`로 저장소 밖에서 실행한다.
- `--ignore-user-config`와 `--ignore-rules`는 항상 쌍으로 쓴다. 단 이 조합이 차단하지 못하는
  표면이 있다 — cwd 기반 project 축(project `AGENTS.md`, `.agents/skills` 투영)은 이 플래그의
  대상이 아니며 cwd 이동만이 유일한 차단 수단이다 (재확인: 2026-08-15, 0.147.0 —
  `codex debug prompt-input`으로 모델 가시 컨텍스트를 덤프해 대조: project cwd에서는 두 마커가
  모두 존재하고, 동일 조건의 clean cwd에서는 둘 다 사라진다).
- 격리가 실제로 걸렸는지는 모델 호출 없이 검증할 수 있다 — `codex debug prompt-input '<프롬프트>'`가
  모델에 실제로 들어가는 컨텍스트를 JSON으로 덤프하므로, 격리 대상 문자열이 남아 있는지
  grep한다 (`--ignore-user-config`는 이 debug 서브커맨드에서 미지원이라 rc 2로 거부된다 — 그
  플래그의 효과는 exec 배너·실행으로 확인한다).
- 출력은 untrusted로 취급하고, 프롬프트에 홈/전역 재귀 검색을 지시하지 않는다.

## 운영 체크리스트

실행 전:
- `command -v codex`로 비대화형 PATH를 확인하고, programmatic 경로는 `command -v codex-exec-supervised && codex-exec-supervised --check`까지 통과
- `command codex --version`으로 기대 버전 확인
- `pwd`가 대상 저장소 루트인지 확인
- 프롬프트 파일 경로와 결과 파일 경로를 분리
- fan-out 전 패턴 8 스모크 1회 통과

실행 후:
- CLI/wrapper exit 보존 및 확인
- 결과 파일이 비어 있지 않은지 + 형식 계약(완료 표식·JSON 파싱)을 만족하는지 확인 (성공 계약 조건 2)
- rc 또는 결과 파일 판정이 실패했을 때만 stderr를 원인 분류에 사용 (known-issues.md §0-1 — `ERROR:` grep을 판정에 쓰지 않는다)
- 반복 작업이면 직전 결과 대비 진척 delta 확인

## 하지 말아야 할 패턴

| 금지 패턴 | 발생 에러 | 올바른 대안 |
|-----------|----------|------------|
| review에서 PROMPT + scope flag | `'[PROMPT]' cannot be used with '--base'` | 의사결정 트리의 방법 A 또는 B |
| exec 전용 플래그를 review에 전달 | `unexpected argument` | [CLI 호환성 매트릭스](cli-reference.md#호환성-매트릭스) 확인 |
| PROMPT 인자와 `-` 마커 동시 사용 | `unexpected argument '-'` | PROMPT 또는 stdin marker 중 하나만 선택 |
| programmatic 자동화에서 `resume --last` 사용 | 무저장 cwd에서 무출력 hang(0.147.0) 또는 새 세션 silent fallback(0.144.1) — gotcha 4 | 세션 id 명시 + supervised 경로 + session id·응답 context 확인 |
| programmatic 호출에 raw `codex exec` 사용 | hang/자식 프로세스 잔존 | [실행 경로 게이트](../SKILL.md#실행-경로-게이트)의 supervised wrapper 사용 |
| `-c hooks.*` inline override | stdin과 무관한 silent hang 가능 | override 제거 + §15 supervisor 적용 |
| JSON parser 앞 `2>&1` | stderr 혼입으로 JSON 파싱 실패 | stdout/stderr/result 분리 |
| stderr `ERROR:` grep을 1차 실패 판정에 사용 | 프롬프트 에코·tracing으로 정상 실행 상시 오탐 + timeout·pre-flight 미탐 | rc + 결과 파일이 정본, stderr는 known-issues §0-1 분류 전용 |
| background 발사 말미의 꼬리 echo/cat | 완료 알림이 래핑 셸 rc(0)를 보고 — 전건 실패가 completed | rc 캡처 → `.rc` 영속화 → `exit $rc` (성공 계약 "background 발사의 rc 계약") |
| 판정 pipeline 끝에 `head`/`tail`/`; echo $?` | 원 exit 은폐 | `pipefail`과 즉시 exit 보존 |
| `-m o3` / `-m o4-mini` 등 비Codex 모델 지정 | "Model metadata not found" + "model is not supported" | `-m` 생략, 기본 모델 사용 |
| `-m` 플래그로 매번 다른 모델 지정 | 불일치/에러 위험 | [모델 사용 원칙](cli-reference.md#모델-사용-원칙) |
| 실패 원인 미확인 후 반복 재시도 | 동일 에러 반복 | known-issues.md 진단 절차 |
| 긴 루프에서 결과 파일 저장 생략 | 결과 유실 | `-o` 또는 리다이렉트 필수 사용 |
| child가 같은 collector/fan-out을 다시 생성 | 무한 자기증식 | 오케스트레이션은 부모 1계층에서만 수행 |
| 공개 exec `--json`의 빈 `receiver_thread_ids`를 spawn 실패로 판정 | `wait` 이벤트 필드일 뿐 — child는 실행됐을 수 있어 오판·중복 실행 | persisted rollout에서 `spawn_agent` 확인 ([known-issues.md §19](known-issues.md#19-codex-exec---json이-multi-agent-spawnchild-이벤트를-노출하지-않음-관측성-한계)) |
