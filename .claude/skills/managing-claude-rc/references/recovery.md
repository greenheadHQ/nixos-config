# 재시작과 복구

## 같은 cwd의 unmanaged 서버 정리

`claude-rc` 관리 밖에서 띄운 `claude remote-control` 서버가 같은 디렉토리에서 아직 떠 있으면
`claude-rc-maint`는 `unmanaged-server-present`로 기동을 거부한다. 같은 디렉토리에 두 번째 서버를
띄우면 삭제 불가능한 유령 환경이 생기므로, 이 거부가 정상 안전장치다. 아래 확인은 코드
(`modules/nixos/scripts/claude-rc-lib.sh`의 `find_bridge_pids_for_path`)와 같은 기준을 따른다.

1. 후보를 모은다. 패턴은 코드의 `BRIDGE_PROCESS_PATTERN`과 같아서 `remote-control`과 공식 별칭
   `rc`를 모두 잡는다. 결과는 후보 목록일 뿐 종료 대상이 아니다.

   ```bash
   pgrep -u "$(id -u)" -fl 'remote-control|[[:space:]]rc([[:space:]]|$)'
   ```

2. 후보마다 아래를 모두 확인하고, 하나라도 맞지 않으면 대상에서 뺀다.
   - argv: `ps -ww -o args= -p <PID>`에서 CLI 명령 자리에 `remote-control` 또는 `rc`가 있다.
     `-p`·`--print`·`--` 뒤에 나오는 같은 글자는 명령이 아니라 데이터다.
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

   대상으로 확정한 PID의 시작 시각과 argv를 기록한다. 3단계는 이 기록과 같은 셸에서 실행한다.

   ```bash
   CLAUDE_RC_UNMANAGED_PID=<확인한 PID>
   CLAUDE_RC_UNMANAGED_LSTART="$(ps -o lstart= -p "$CLAUDE_RC_UNMANAGED_PID")"
   CLAUDE_RC_UNMANAGED_ARGS="$(ps -ww -o args= -p "$CLAUDE_RC_UNMANAGED_PID")"
   ```

3. 그 대상에 대한 작업 직전 승인을 받은 뒤 아래를 실행한다. 서버를 식별할 수 없으면 종료하지
   않는다.

   ```bash
   : "${CLAUDE_RC_UNMANAGED_PID:?2단계에서 확인하고 승인받은 PID를 설정하세요}"
   : "${CLAUDE_RC_UNMANAGED_LSTART:?2단계에서 기록한 시작 시각을 설정하세요}"
   : "${CLAUDE_RC_UNMANAGED_ARGS:?2단계에서 기록한 argv를 설정하세요}"
   # 승인을 기다리는 사이 서버가 끝나고 OS가 PID를 재사용했을 수 있다. 신호 직전에 시작 시각과
   # argv를 다시 읽어 기록과 같을 때만 kill한다. 재사용된 PID가 같은 초에 시작하고 argv까지 같을
   # 수는 사실상 없으므로, 2단계에서 확인한 cwd·실행 파일은 다시 보지 않는다.
   if [ "$(ps -o lstart= -p "$CLAUDE_RC_UNMANAGED_PID" 2>/dev/null)" = "$CLAUDE_RC_UNMANAGED_LSTART" ] &&
     [ "$(ps -ww -o args= -p "$CLAUDE_RC_UNMANAGED_PID" 2>/dev/null)" = "$CLAUDE_RC_UNMANAGED_ARGS" ]; then
     kill "$CLAUDE_RC_UNMANAGED_PID"
   else
     echo "대상이 바뀌었으니 2단계부터 다시 확인한다" >&2
   fi
   ```

   kill이 실패하거나(권한 없음, 이미 종료됨 등) 대상이 바뀌었다는 안내가 나오면 4단계로 넘어가지
   말고 2단계부터 다시 확인한다.

4. `ps -p "$CLAUDE_RC_UNMANAGED_PID"`로 종료를 확인한 뒤 해당 Git 디렉토리에서 `claude-rc start`를
   실행한다. 서버가 아직 떠 있으면 `claude-rc start`는 같은 이유로 다시 거부한다. 선언 인스턴스는
   수동 `claude-rc start` 대신 다음 ensure 주기에 자동 기동시켜도 된다. 같은 디렉토리 경로이므로
   기존 claude.ai 환경을 회수한다.

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
  status="$HOME/.local/state/claude-rc/status.json"
  CLAUDE_RC_DRIFT_POLICY=defer claude-rc-maint ensure >&2
  jq -e '.action == "completed" and .exitCode == 0' "$status" >/dev/null
  jq -c '[.instances[]
    | select(.action == "deferred-restart-confirmation")
    | {path, runningVersion, desiredVersion}]
    | sort_by([.path, .runningVersion, .desiredVersion])' "$status"
)"
jq -e 'length > 0' <<<"$approval" >/dev/null
jq -r '.[] | [.path, .runningVersion, .desiredVersion] | @tsv' <<<"$approval"
claude-rc ls
```

block 전체가 exit 0일 때만 출력된 후보를 승인 목록으로 쓴다. 후보 전체를 이름으로 포함해
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
