# 실행 방식별 예제

실행 전 [실행 계약](execution-contracts.md)을 적용한다. 플래그 조합은 [CLI 참조](cli-reference.md)를 따른다.

## 표준 실행 절차

NixOS에서 `-s read-only` / `-s workspace-write`는 bubblewrap 경로를 사용한다. system bwrap 부재 시
bundled fallback과 nested bwrap 기각 결과는 [known-issues.md §16](known-issues.md#16-nixos-bwrap-의존)을 참조한다.

### 일반 exec — Claude Code·headless 자동화

프롬프트를 파일로 작성하고, stdin 파이프로 전달하며, `-o`로 결과를 저장한다.
아래 고정 `/tmp` 경로는 단일 수동 실행 데모다 — 동시/병렬 실행은 결과·로그를 서로 덮어쓰므로
세션별 네임스페이스 디렉토리로 격리한다 ([known-issues.md §12](known-issues.md#12-동시-다중-세션-간-tmpda--경쟁-상태);
경로 격리 시 임의 suffix의 literal 재사용 규칙은 [#632 절](known-issues.md#literal-재사용-시-random-suffix-환각-금지-issue-632)을 따른다):

```bash
cat > /tmp/prompt.md <<'PROMPT'
이 변경의 배포 리스크를 3개 이내로 지적한다.
PROMPT
```

⚠️ `run_in_background` 환경: 여기서 Bash tool 호출을 종료하고, 아래를 별도 호출로 실행한다 ([§11](known-issues.md) 하위 항목).

```bash
# marker must apply to `codex`, not `cat` (issue #585): Codex 0.124+ user-level hooks의 early-exit 신호.
rm -f /tmp/result.md   # 이전 실행의 non-empty 잔존 결과로 인한 오판 방지
set -o pipefail
cat /tmp/prompt.md | env CODEX_PROGRAMMATIC=1 codex-exec-supervised \
  -s workspace-write -o /tmp/result.md - \
  > /tmp/stdout.log 2> /tmp/stderr.log
# PIPESTATUS는 다음 명령에서 리셋되므로 배열을 먼저 스냅샷한다. cat 실패(프롬프트 파일 부재)도 판정에 포함.
pipe_rcs=("${PIPESTATUS[@]}")   # zsh는 ("${pipestatus[@]}") — 인덱스가 1부터
[ "${pipe_rcs[0]}" -eq 0 ] && [ "${pipe_rcs[1]}" -eq 0 ] && test -s /tmp/result.md
# 판정은 rc + 결과 파일이 정본이다. 위가 실패했을 때만 /tmp/stderr.log를 원인 분류에 사용한다
# (성공 계약 조건 3; ANSI·프롬프트 에코 함정과 분류 절차는 known-issues.md §0-1).
```

위의 `test -s` 빈 결과 검증은 wrapper에 위임할 수도 있다 (opt-in, issue #1228):
`CODEX_EXEC_REQUIRE_NONEMPTY=<결과 파일 절대경로>`를 설정하면 codex가 exit 0인데 그 경로가
non-empty regular file이 아닐 때 wrapper가 rc 3 + stderr 식별자
`codex-exec-supervised: empty output`으로 실패한다.

- 판별은 rc 3 단독이 아니라 rc 3 + 해당 stderr 식별자 조합으로 한다 — codex passthrough
  규약상 codex 자체도 3을 반환할 수 있다 (식별자 부재 = codex의 3).
- 호출자 계약: 실행 전 대상 파일을 삭제/초기화해야 한다. 이전 실행의 stale 파일이 있으면
  이번 실행이 아무것도 안 써도 통과한다 (위 예시의 `rm -f /tmp/result.md`가 그 역할).
- timeout rc(124/137)와 codex 오류 rc는 덮어쓰지 않는다 — 검사는 codex rc 0일 때만 수행된다.
- 값은 절대경로만 허용 (빈 값·상대경로는 invalid env 규약대로 exit 127).

wrapper 계약 요약 — wrapper에는 자체 `--help`가 없고(`--help`는 codex exec로 passthrough)
배포 경로는 nix shim이므로, 정본은 저장소 스크립트(`modules/shared/scripts/codex-exec-supervised.sh`)
헤더와 아래 요약이다. 런타임 확인 경로로는 `codex-exec-supervised --check`가 성공 시 같은
목록(정본 env 5개·exit code 규약)을 stderr로 출력한다 — 이 출력은 PR #1248에서 추가되므로,
그 변경이 배포되기 전에는 `precheck OK ...` 한 줄만 나온다:

| 축 | 계약 |
|----|------|
| 정본 env 5개 | `CODEX_EXEC_TIMEOUT_SECONDS`(기본 1800, 상한 7200) / `CODEX_EXEC_KILL_AFTER_SECONDS`(기본 5) / `CODEX_EXEC_TIMEOUT_BIN` / `CODEX_EXEC_SETSID_BIN` / `CODEX_EXEC_REQUIRE_NONEMPTY`. 계열 이름의 오타는 exit 127로 fail-fast |
| exit code | 0=정상 / 124·137=timeout(SIGTERM/SIGKILL) / 127=사전 검증 실패(BLOCKED) / 3+stderr 식별자=REQUIRE_NONEMPTY 실패 / 기타=codex rc |
| env 부착 위치 | `CODEX_EXEC_*`는 파이프 오른쪽 wrapper 호출 앞에만 (`cat f \| CODEX_EXEC_TIMEOUT_SECONDS=600 codex-exec-supervised ...`) — 왼쪽 명령 앞은 무효 |
| `--check` | 단독 첫 인수로만. env+deps만 검증한다 — cwd trust·샌드박스·모델 가용성은 미포함 |
| 인수 전개 | wrapper 인수는 `codex exec` 뒤에 그대로 전개된다 (순수 passthrough — 인자 해석·변형 없음) |
| 수정 시 | 정본 스크립트 수정 후 재배포(activation) 전에는 배포본 live 검증 금지 (shim이 구 버전을 가리킴) |

상세 계약은 [known-issues.md §15](known-issues.md#15-codex-exec-supervised-wrapper로-14-위에-timeout-budget-한계-보강-issue-593)를 참조한다.

사용자가 literal raw 실행을 요청한 1회성 수동 진단에서는 인라인 프롬프트도 가능하다:

```bash
env CODEX_PROGRAMMATIC=1 codex exec -s workspace-write "git diff 기준으로 회귀 가능성 한 줄 요약"
```

### 코드 리뷰 — scope flag만 사용 (Claude Code·headless 자동화)

아래 세 명령은 순차 실행하는 파이프라인이 아니라 scope별 택일 대안이다.
선택한 하나만 실행하고, 실행 전 결과 파일을 초기화하며, 종료 후 성공 계약을 검증한다:

```bash
rm -f /tmp/review.md   # 이전 실행의 잔존 결과로 인한 오판 방지

# 셋 중 하나를 선택:
env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --base main \
  -o /tmp/review.md > /tmp/review-stdout.log 2> /tmp/review-stderr.log
# env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --uncommitted ... (동일 형태)
# env CODEX_PROGRAMMATIC=1 codex-exec-supervised review --commit <sha> ... (동일 형태)

review_rc=$?
[ "$review_rc" -eq 0 ] && test -s /tmp/review.md
# 실패 시에만 /tmp/review-stderr.log로 원인을 분류한다 (성공 계약 조건 3, known-issues.md §0-1).
```

stderr는 실패 판정 입력이 아니라 원인 분류 입력이다 (성공 계약 조건 3). stderr에는
프롬프트 전문 에코와 최종 메시지 사본이 정상 실행에도 남으므로, `ERROR:` grep을 판정에
쓰면 성공 실행이 실패로 뒤집힌다 (2026-08-15, 0.147.0 실측).

review 결과 저장에는 `-o`(`--output-last-message`)와 stdout이 모두 동작한다
(재확인: 2026-07-10, 0.144.1). upstream #12502는 open이지만 로컬에서는 stderr 회귀가
재현되지 않았다. 이슈 상태와 로컬 동작은 [known-issues.md §2](known-issues.md)를 참조한다.

### 코드 리뷰 — 커스텀 지시 필요

PROMPT과 scope flag이 상호 배타이므로, 두 가지 대안 중 선택한다:

방법 A — AGENTS.md 활용 (영구 지시, review diff 스코핑 유지)

프로젝트 `AGENTS.md` 또는 `~/.codex/AGENTS.override.md`에 리뷰 정책을 배치한 뒤,
scope flag으로 review를 실행하면 지시가 적용된다 — 단 적용 범위가 제한적이다
(재확인: 2026-08-15, 0.147.0 — 임시 repo marker 실측 4회):

| 지시 유형 | `codex exec` | `codex exec review` |
|-----------|-------------|---------------------|
| 내용·스코프 ("보안만 지적, 스타일 금지") | 적용 | 적용 (대조군 대비 스타일 지적 억제 확인) |
| 출력 형식 (첫 줄 marker, 항목 끝 태그) | 적용 | 미적용 (2회 일관) |

즉 방법 A로는 리뷰의 관점·범위를 바꿀 수 있지만 출력 형식은 강제할 수 없다. review에서
`--output-schema`도 silent no-op이므로(gotcha 11), 형식·구조화 출력이 필요하면 방법 B가 유일하다.
(지시 파일 우선순위: [references/patterns.md](patterns.md) 패턴 3 참조 — 깊이별 우선순위는 재검증 미수행)

방법 B — exec 우회 (1회성 지시, 최대 유연성)

`codex exec` (review 미사용)에 `git diff` 출력과 커스텀 지시를 프롬프트로 직접 전달한다.
`-o`로 결과 저장이 가능하고, 프롬프트 내용을 자유롭게 구성할 수 있다.

상세 명령과 예제: [references/patterns.md](patterns.md) 패턴 3, 4

### 세션 재개

Claude Code/headless의 programmatic 재개는 supervised 경로를 사용한다:

```bash
SESSION="<session-id>"   # 재개할 세션 id
rm -f /tmp/resume-result.md
env CODEX_PROGRAMMATIC=1 codex-exec-supervised resume "$SESSION" \
  -o /tmp/resume-result.md > /tmp/resume-stdout.log 2> /tmp/resume-stderr.log
resume_rc=$?

# silent fallback 검증: 반환된 session id가 요청한 세션과 일치해야 하며, 최종 판정에 연결한다.
# 배너의 "session id:"에는 ANSI escape가 낄 수 있다(하네스가 FORCE_COLOR를 주입하는 환경 실측 —
# ESC[1msession id:ESC[0m <uuid> 형태라 평문 grep -F가 항상 실패). resume에는 --color 플래그가
# 없으므로(exec 전용) ANSI 제거 후 매치가 유일한 일반해다.
sed $'s/\x1b\\[[0-9;]*m//g' /tmp/resume-stderr.log > /tmp/resume-stderr.plain
# 배너에서 값을 추출해 문자열 그대로 비교한다 — `grep -E "...$SESSION"`은 (a) 값이 ERE로
# 해석되고(thread name 수용 이후 메타문자 위험) (b) 뒤 경계가 없어 접두사 일치도 통과시킨다.
banner_session=$(sed -n 's/.*session id:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
  /tmp/resume-stderr.plain | head -1)
[ "$resume_rc" -eq 0 ] \
  && [ "$banner_session" = "$SESSION" ] \
  && test -s /tmp/resume-result.md
# 위 판정 실패, 또는 응답(/tmp/resume-result.md)이 원 세션의 context를 잇지 않으면 재개 실패로 처리한다.
# --json 사용 시 stderr 배너 자체가 사라진다 — stdout의 thread.started 이벤트 `thread_id`를 비교한다.
```

변형: `resume --last` (같은 cwd의 마지막 세션), `resume --last --all` (cwd 필터 해제).
`[SESSION_ID]` 인자는 UUID 외에 thread name도 수용하며 UUID가 파싱되면 우선한다 (0.147.0 help).
programmatic 자동화에서는 `--last`를 쓰지 말고 세션 id를 명시한다 — [실행 계약 Gotchas](execution-contracts.md#gotchas) 4번의 두 실패
축이 모두 `--last` + 무저장 cwd 조합에서 발생하고, raw 호출에는 timeout 구제가 없다.

`--ephemeral` 세션은 저장되지 않는다. 저장 세션이 없는 cwd의 `resume --last`는 버전·환경에
따라 (a) 새 session id로 조용히 시작해 exit 0 (0.144.1 관측 — silent fallback 로직은 0.147.0에도
잔존), 또는 (b) 배너조차 없는 무출력 무기한 정지 (0.147.0 실측 5/5, 300초까지 무출력 — 대형
세션 코퍼스·state DB 환경에서 관측된 시그니처로 wrapper timeout rc 124가 유일한 구제) 중
하나로 나타난다 — 위 예제가 session id·응답 context 확인을 포함하고 supervised 경로를 강제하는
이유다. 불일치하거나 결과가 비면 재개 실패로 처리한다. 상세 시그니처는
[known-issues.md의 resume 실패 시그니처](known-issues.md) 참조.
