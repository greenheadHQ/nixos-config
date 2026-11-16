# 재시작과 복구

## 같은 cwd의 unmanaged 서버 정리

`claude-rc` 관리 밖에서 띄운 `claude remote-control` 서버가 같은 디렉토리에서 아직 떠 있으면
`claude-rc-maint`는 `unmanaged-server-present`로 기동을 거부한다. 같은 디렉토리에 두 번째 서버를
띄우면 중복 환경과 비활성 목록 항목이 생길 수 있으므로, 이 거부는 유지한다.
`find_bridge_pids_for_path`는 모호한 후보도 새 기동을 막는 쪽으로 판정한다. 그 후보 판정만으로
종료 대상을 확정하지 않고, 아래에서 실제 argv 경계·cwd·실행 파일·관리 상태를 확인한다.

아래 명령은 이 저장소 루트에서 `nix develop --command bash`로 연 Bash 셸에서 실행한다. argv는 배포된
래퍼가 사용하는 `claude-rc-pid-argv` helper로 읽는다. 이 helper는 일반 PATH에 노출되지 않을 수
있으므로, 현재 래퍼 패키지의 참조에서 실행 파일 하나를 찾는다. 조회 실패·0개·여러 개면
진행하지 않는다. `ps args` 문자열로 대체하지 않는다.

```bash
CLAUDE_RC_PID_ARGV_HELPER="$(
  set -euo pipefail
  wrapper="$(type -P claude-rc)" || exit 1
  wrapper="$(readlink -f "$wrapper")" || exit 1
  case "$wrapper" in /nix/store/*/bin/claude-rc) ;; *) exit 1 ;; esac
  references="$(nix-store --query --references "$(dirname "$(dirname "$wrapper")")")" || exit 1
  helpers=()
  while IFS= read -r reference; do
    helper="$reference/bin/claude-rc-pid-argv"
    [ ! -x "$helper" ] || helpers+=("$helper")
  done <<<"$references"
  [ "${#helpers[@]}" -eq 1 ] || exit 1
  printf '%s\n' "${helpers[0]}"
)"
```

위 명령이 성공하고 `CLAUDE_RC_PID_ARGV_HELPER`가 비어 있지 않을 때만 다음으로 진행한다.

1. 후보를 모은다. 패턴은 코드의 `BRIDGE_PROCESS_PATTERN`과 같아서 `remote-control`과 공식 별칭
   `rc`를 모두 잡는다. 결과는 후보 목록일 뿐 종료 대상이 아니다.

   ```bash
   pgrep -u "$(id -u)" -fl 'remote-control|[[:space:]]rc([[:space:]]|$)'
   ```

2. 후보의 argv를 NUL 구분 그대로 임시 파일에 저장하고, 인자마다 따로 표시한다. `%q` 표시는
   인자 안의 공백·개행과 인자 경계를 구분하기 위한 것이다. helper 실패나 빈 출력이면 진행하지
   않는다. 아래 PID 값은 확인할 후보로 채운다.

   ```bash
   : "${CLAUDE_RC_PID_ARGV_HELPER:?배포된 argv helper를 먼저 확인하세요}"
   CLAUDE_RC_UNMANAGED_PID=
   : "${CLAUDE_RC_UNMANAGED_PID:?확인할 후보 PID를 입력하세요}"
   CLAUDE_RC_UNMANAGED_ARGV_FILE="$(mktemp)"
   if "$CLAUDE_RC_PID_ARGV_HELPER" "$CLAUDE_RC_UNMANAGED_PID" >"$CLAUDE_RC_UNMANAGED_ARGV_FILE" &&
     [ -s "$CLAUDE_RC_UNMANAGED_ARGV_FILE" ]; then
     argv_index=0
     while IFS= read -r -d '' arg; do
       printf 'argv[%d]=%q\n' "$argv_index" "$arg"
       argv_index=$((argv_index + 1))
     done <"$CLAUDE_RC_UNMANAGED_ARGV_FILE"
   else
     rm -f "$CLAUDE_RC_UNMANAGED_ARGV_FILE"
     unset CLAUDE_RC_UNMANAGED_ARGV_FILE
     echo "argv를 읽지 못했으니 종료 대상으로 삼지 않는다" >&2
     false
   fi
   ```

   다음 조건을 모두 확인하고, 하나라도 확인할 수 없으면 대상에서 뺀다.
   - argv: `remote-control` 또는 `rc`가 독립된 CLI 명령 인자다. `-p`·`--print`·`--` 뒤의
     같은 글자나 다른 옵션 값에 포함된 글자는 명령이 아니다. 현재 CLI 문법에서 명령 위치를
     확정하지 못하면 종료하지 않는다.
   - cwd: 심링크를 푼 인스턴스 디렉토리 경로(`pwd -P`)와 같다.
     - NixOS: `readlink /proc/<PID>/cwd`
     - macOS: `lsof -a -p <PID> -d cwd -Fn`의 `n` 행
   - 실행 파일: 버전 디렉토리 `~/.local/share/claude/versions`(코드의 `VERSIONS_DIR` 기본값)에 있는
     Claude 바이너리다. flock, `claude-rc-launch-group`, nohup, 셸 같은 래퍼는 argv에
     `remote-control`이 있어도 서버가 아니며, flock 프로세스는 항상 뺀다.
     - NixOS: `readlink /proc/<PID>/exe`. 삭제된 구버전이면 끝에 ` (deleted)`가 붙는다.
     - macOS: `lsof -a -p <PID> -d txt -Fn`의 첫 `n` 행. 같은 파일의 하드링크 별칭 경로가 나올 수
       있으므로, 버전 디렉토리 밖 경로면
       `[ "<실행 파일 경로>" -ef ~/.local/share/claude/versions/<버전> ]`로 같은 파일인지 확인한다.
   - `claude-rc ls`가 관리하는 서버가 아니다.

   프로세스 이름, 세션 이름, 표시용 command/path만으로 대상을 확정하지 않는다. 대상은 서버 PID
   하나이며, 그 서버를 띄운 터미널·셸·부모 프로세스는 다른 작업이 있을 수 있으므로 종료하지 않는다.
   대상으로 확정한 PID의 시작 시각을 기록한다. 3단계는 argv 파일을 보존한 같은 셸에서 실행한다.

   ```bash
   CLAUDE_RC_UNMANAGED_LSTART="$(ps -o lstart= -p "$CLAUDE_RC_UNMANAGED_PID")"
   : "${CLAUDE_RC_UNMANAGED_LSTART:?시작 시각을 읽지 못했으니 다시 확인하세요}"
   ```

3. 그 대상에 대한 작업 직전 승인을 받은 뒤, 2단계의 cwd·실행 파일·관리 상태를 다시 확인한다.
   어느 하나라도 바뀌었거나 확인할 수 없으면 종료하지 않는다. 아래 명령은 시작 시각과 NUL argv
   전체도 다시 비교하고, 일치할 때만 해당 서버 PID에 신호를 보낸다.

   ```bash
   : "${CLAUDE_RC_UNMANAGED_PID:?2단계에서 확인하고 승인받은 PID를 설정하세요}"
   : "${CLAUDE_RC_UNMANAGED_LSTART:?2단계에서 기록한 시작 시각을 설정하세요}"
   : "${CLAUDE_RC_UNMANAGED_ARGV_FILE:?2단계에서 저장한 argv 파일을 설정하세요}"
   signal_status=1
   if CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE="$(mktemp)" &&
     "$CLAUDE_RC_PID_ARGV_HELPER" "$CLAUDE_RC_UNMANAGED_PID" >"$CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE" &&
     [ -s "$CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE" ] &&
     [ "$(ps -o lstart= -p "$CLAUDE_RC_UNMANAGED_PID" 2>/dev/null)" = "$CLAUDE_RC_UNMANAGED_LSTART" ] &&
     cmp -s "$CLAUDE_RC_UNMANAGED_ARGV_FILE" "$CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE"; then
     kill "$CLAUDE_RC_UNMANAGED_PID" && signal_status=0
   else
     echo "대상을 재확인할 수 없으니 2단계부터 다시 확인한다" >&2
   fi
   [ -z "${CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE:-}" ] || rm -f "$CLAUDE_RC_UNMANAGED_CURRENT_ARGV_FILE"
   [ "$signal_status" -eq 0 ]
   ```

   kill이 실패하거나(권한 없음, 이미 종료됨 등) 재확인 안내가 나오면 4단계로 넘어가지 말고
   2단계부터 다시 확인한다. 사용을 마친 argv 임시 파일은 지운다.

4. `ps -p "$CLAUDE_RC_UNMANAGED_PID"`로 종료를 확인한 뒤 해당 Git 디렉토리에서 `claude-rc start`를
   실행한다. 서버가 아직 떠 있으면 `claude-rc start`는 같은 이유로 다시 거부한다. 선언 인스턴스는
   수동 `claude-rc start` 대신 다음 ensure 주기에 자동 기동시켜도 된다.
   [환경 회수 조건](lifecycle.md#환경과-세션-수명주기)에 따르면 같은 경로라도 보존 세션이 있어야
   기존 claude.ai 환경을 회수하며, 세션이 없으면 새 환경과 비활성 항목이 생길 수 있다.
   이 조건은 문서의 실측 범위를 따르며, upstream 버전·launcher가 바뀌면 다시 확인한다.

   ```bash
   rm -f "$CLAUDE_RC_UNMANAGED_ARGV_FILE"
   unset CLAUDE_RC_UNMANAGED_ARGV_FILE
   ```

## 트러블슈팅

공통:

```bash
claude-rc ls
cat ~/.local/state/claude-rc/status.json
tail -50 ~/.local/state/claude-rc/<slug>/server.log
pgrep -u "$(id -u)" -fl 'remote-control|[[:space:]]rc([[:space:]]|$)'
```

`pgrep` 행은 launcher basename과 무관한 후보 수집용이다. 결과를 managed process로 단정하거나
signal하지 말고, `claude-rc ls`와 exact argv token, cwd, version root, trusted `flock`, lock lineage를
모두 검증한다.

NixOS:

```bash
journalctl -u claude-rc-ensure --since -2d
systemctl list-timers claude-rc-ensure
```

아래 recovery는 죽은 bridge를 시작하거나 version drift bridge를 재시작할 수 있다. 실행 직전에
운영자의 action-time confirmation을 받은 뒤 한 명령만 실행한다.

```bash
systemctl start claude-rc-ensure
```

macOS:

```bash
launchctl list | grep claude-rc
launchctl print "gui/$(id -u)/org.nix-community.home.claude-rc-ensure"
tail -50 ~/Library/Logs/claude-rc-ensure.log
# no-server-process 판정 시 탈락 술어(cwd/exe/lineage/lock) 확인
grep -n 'scan-rejects' ~/Library/Logs/claude-rc-ensure.log | tail -20
```

아래 명령은 현재 상태를 즉시 ensure한다. 죽은 bridge는 시작하지만 live version drift는
`deferred-restart-confirmation`으로 남기므로 periodic job과 같은 liveness-only 정책이다.

```bash
launchctl kickstart "gui/$(id -u)/org.nix-community.home.claude-rc-ensure"
```

수동 restart는 승인된 path/version 집합만 lifecycle lock 안에서 재검증한다. 먼저 `defer` 정책으로
동기 snapshot을 쓰고, `deferred-restart-confirmation`인 전체 path/version 후보와 현재
`claude-rc ls`를 운영자에게 제시한다. 아래 `approval` JSON은 같은 shell에서 보존한다.

```bash
approval="$(
  set -euo pipefail
  status_file="$HOME/.local/state/claude-rc/status.json"
  CLAUDE_RC_DRIFT_POLICY=defer claude-rc-maint ensure >&2 || exit "$?"
  jq -e '.action == "completed" and .exitCode == 0' "$status_file" >/dev/null || exit "$?"
  restart_candidates="$(jq -c '[.instances[]
    | select(.action == "deferred-restart-confirmation")
    | {path, runningVersion, desiredVersion}]
    | sort_by([.path, .runningVersion, .desiredVersion])' "$status_file")" || exit "$?"
  if [ "$restart_candidates" = '[]' ]; then
    printf '%s\n' '재시작 후보가 없습니다. 승인·재시작 단계로 진행하지 않습니다.' >&2
    exit 2
  fi
  jq -r '.[] | [.path, .runningVersion, .desiredVersion] | @tsv' <<<"$restart_candidates" >&2 || exit "$?"
  claude-rc ls >&2 || exit "$?"
  printf '%s\n' "$restart_candidates"
)"
```

후보 표와 현재 목록은 stderr에 표시하고, 모든 명령이 성공한 뒤에만 `approval`에 JSON을 넣는다.
블록 전체가 exit 0이고 `approval`이 비어 있지 않을 때만 출력된 후보를 승인 목록으로 쓴다.
후보가 없으면 별도 안내와 exit 2로 끝나며 `approval`은 비어 있으므로 승인 단계로 진행하지 않는다.
snapshot 생성·검증·추출이나 현재 목록 조회가 실패한 경우도 승인 값을 남기지 않는다.
후보 전체를 이름으로 포함해
action-time confirmation을 한 번 받고 처음의 exact JSON을 stable home symlink maint에 전달한다.
`confirmed`는 lifecycle lock을 잡은 뒤 현재 `(path,runningVersion,desiredVersion)` 집합을 다시 계산해
approval과 exact match하는 경우만 restart한다. 어느 명령이나 status 검증이 실패하거나 runtime
snapshot이 달라졌으면 restart하지 않고 새 `defer` snapshot으로 승인부터 다시 수행한다. one-shot
policy/approval env는 새 bridge에 상속되지 않는다.

```bash
CLAUDE_RC_DRIFT_POLICY=confirmed \
CLAUDE_RC_DRIFT_APPROVAL_JSON="$approval" \
  claude-rc-maint ensure
```
