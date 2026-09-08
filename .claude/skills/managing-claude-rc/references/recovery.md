# 마이그레이션과 복구

## 기존 tmux bridge에서 마이그레이션

구 tmux 기반 bridge가 같은 디렉토리에서 아직 떠 있으면 새 `claude-rc-maint`는
`unmanaged-server-present`로 기동을 거부한다. 같은 디렉토리에 두 번째 서버를 띄우면
삭제 불가능한 유령 환경이 생기므로, 이 거부가 정상 안전장치다.

먼저 `tmux list-panes -a -F '#{session_id} #{window_id} #{pane_id} #{pane_pid} #{pane_tty} #{pane_current_path} #{pane_current_command}'`로 세션과 pane을 식별한다. `pane_pid`는 pane의 첫 프로세스이므로 bridge를 시작한 셸일 수 있다. 그 PID 자체와 자손을 프로세스 트리 및 pane TTY와 대조해 실제 `claude remote-control` 프로세스를 찾고, 그 PID의 전체 argv와 실제 cwd로 같은 디렉토리의 구 bridge인지 확인한다. TTY나 표시용 command/path만으로 bridge를 확정하지 않는다. 그 세션의 모든 window/pane에 다른 작업이 없는지 확인하고, 이름이 `claude-rc`라는 이유만으로 세션을 종료하지 않는다.

확인한 실제 `session_id`를 `CLAUDE_RC_SESSION_ID`에 설정하고, 그 대상에 대한 작업 직전 승인을 받은 뒤 해당 Git 디렉토리에서 아래를 실행한다. 대상이나 실행 중 작업이 달라졌으면 먼저 다시 확인한다. 세션에 다른 작업이 있거나 bridge를 식별할 수 없으면 세션 전체를 종료하지 않는다.

```bash
: "${CLAUDE_RC_SESSION_ID:?확인하고 승인받은 tmux session_id를 설정하세요}"
tmux kill-session -t "$CLAUDE_RC_SESSION_ID" || exit 1
claude-rc start
```

선언 인스턴스는 수동 `claude-rc start` 대신 다음 ensure 주기에 자동 기동시켜도 된다.
같은 디렉토리 경로이므로 기존 claude.ai 환경을 회수한다.

## 트러블슈팅

공통:

```bash
claude-rc ls
cat ~/.local/state/claude-rc/status.json
tail -50 ~/.local/state/claude-rc/<slug>/server.log
pgrep -fl 'remote-control'
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
