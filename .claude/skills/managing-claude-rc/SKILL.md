---
name: managing-claude-rc
description: |
  Manage Claude Code Remote Control bridge (claude-rc): headless multi-instance,
  instance lifecycle, version drift ensure, tombstone recovery, troubleshooting.
  Trigger: 'claude-rc', 'remote control', '리모트 컨트롤', 'bridge 서버', '모바일 세션',
  'claude-rc-ensure', 'claude-rc-maint', '세션 tombstone', 'bridge 재시작'.
  NOT for Codex remote control (use configuring-codex / issuing-codex-pairing-code).
---

# Claude Code Remote Control (claude-rc) 관리

Claude 모바일 앱/claude.ai에서 이 flake가 관리하는 머신의 Claude Code 세션을
원격 조종하는 `claude remote-control` 서버 운영 가이드.

## 개요

`claude-rc`는 headless multi-instance 래퍼다. 인스턴스는 디렉토리 단위이며,
각 디렉토리에서 서버 1개가 해당 claude.ai 환경 1개를 담당한다.

```text
사용자/ensure
  └─ claude-rc / claude-rc-maint
      ├─ STATE_DIR/instances.json 동적 등록
      ├─ STATE_DIR/<slug>/lock 중복 기동 방지
      └─ cd /path/to/project && claude remote-control --spawn <mode> ...
```

- `STATE_DIR` 기본값: `~/.local/state/claude-rc`
- slug: `basename(절대경로)-sha256(절대경로)앞8자`
- 서버 프로세스가 `<slug>/lock`을 `flock`으로 직접 보유한다. lock 생사가 서버 생사다.
- 래퍼를 우회한 순정 CLI 기동은 lock을 보유하지 않으므로, 래퍼는 실행 중
  `claude remote-control` 프로세스의 cwd까지 검사한다.

## 사용자 래퍼

| 명령 | 동작 |
|------|------|
| `claude-rc` / `claude-rc start` | 현재 git top-level 디렉토리 인스턴스 시작 및 `instances.json` 등록 |
| `claude-rc stop` | 현재 인스턴스 서버 종료 및 등록 해제. worktree 세션 존재 시 `--force` 필요 |
| `claude-rc ls` | 등록 인스턴스, 실행 여부, PID, 버전, spawn, source, 로그 경로 출력 |
| `claude-rc cleanup` | 현재 인스턴스의 orphan `.claude/worktrees/*` 디렉토리만 삭제 |

옵션:

| 옵션 | 기본 | 설명 |
|------|------|------|
| `--spawn worktree\|same-dir` | `worktree` | 원격 세션 스폰 방식 |
| `--capacity N` | 미전달 | 동시 세션 수. 미전달 시 upstream 기본값 사용 |
| `--permission-mode MODE` | `bypassPermissions` | `acceptEdits`, `bypassPermissions`, `default`, `dontAsk`, `plan` |
| `--force` | false | `stop`에서 worktree 세션 tombstone 가드 우회 |

이미 실행 중인 인스턴스에 다른 옵션으로 `start`하면 옵션은 반영되지 않는다.
변경하려면 `claude-rc stop` 후 다시 시작한다.

## 상태 레이아웃

```text
~/.local/state/claude-rc/
  instances.json
  instances.json.lock
  ensure.lock
  status.json
  <slug>/
    lock
    server.log
    server.log.1
```

`instances.json` schema v1:

```json
{
  "version": 1,
  "instances": {
    "/path/to/project": {
      "spawn": "worktree",
      "capacity": null,
      "permissionMode": "bypassPermissions",
      "registeredAt": "2026-07-08T12:00:00+09:00",
      "source": "manual"
    }
  }
}
```

- `source=manual`: `claude-rc start`가 등록
- `source=declared`: `claude-rc-maint ensure`가 Nix 선언에서 시드
- `server.log`: 서버 stdout/stderr. 5MB 초과 시 1세대 rotate
- `status.json`: 마지막 ensure 실행 결과. top-level timestamp/exitCode/action과
  인스턴스별 `{path,runningVersion,desiredVersion,action}` 배열을 기록한다.

## 자동화

| 플랫폼 | 자동화 | 선언 위치 |
|--------|--------|-----------|
| NixOS | systemd timer `claude-rc-ensure` 30분 주기 | `homeserver.claudeRemoteControl.*` |
| macOS | launchd agent `claude-rc-ensure` 30분 주기 | `modules/darwin/programs/claude-remote-control.nix` 상수 |

`CLAUDE_RC_DECLARED_INSTANCES`는 JSON 배열이다.

```json
[
  {
    "path": "/path/to/project",
    "spawn": "worktree",
    "capacity": null,
    "permissionMode": "bypassPermissions"
  }
]
```

ensure 판정 흐름:

1. 선언 인스턴스가 `instances.json`에 없으면 `source=declared`로 추가한다.
2. 인스턴스 경로가 없으면 `path-missing`으로 기록하고 등록은 유지한다.
3. lock이 비어 있으면 서버를 headless로 시작한다.
4. 살아 있으면 실행 중 바이너리 버전과 desired Claude launcher 버전을 비교한다.
5. drift가 없으면 `healthy`.
6. drift + `spawn=same-dir`이면 즉시 재시작한다.
7. drift + `spawn=worktree`이면 idle gate를 통과할 때만 재시작한다.

worktree idle gate:

- 최근 `IDLE_THRESHOLD_MINUTES` 내 transcript가 있으면 `deferred-active-sessions`
- `--sdk-url` 세션 프로세스는 있는데 worktree transcript 디렉토리 명명 매치가 0이면
  `deferred-unknown-activity`
- 둘 다 아니면 `restarted-version-drift`

transcript 매칭은 `<정규화된 인스턴스 경로>--claude-worktrees-*`만 본다.
인스턴스 root transcript는 로컬/same-dir 세션 활동일 수 있어 worktree drift gate에
포함하지 않는다.

## 환경과 세션 수명주기

실측 기준: Claude Code v2.1.204.

- 서버 1개 = claude.ai 환경 1개.
- 환경은 디렉토리 경로 기준으로 서버측에 보존되고, 재시작하면 같은 환경을 회수한다.
- 환경 표시명은 upstream이 호스트명 + 디렉토리 basename으로 정한다.
- 같은 디렉토리에 서버 2개가 동시에 뜨면 두 번째가 새 환경을 만든다. 이후 하나만
  회수되고 나머지는 삭제 불가능한 유령 환경으로 영구 잔존한다. 세션 0개여도 목록에
  남고 삭제 UI가 없으며, 죽은 환경이 온라인으로 보일 수 있다.
- 중복 기동 방지는 래퍼의 `flock` + cwd 실측 가드가 유일한 방어다.
- same-dir 스폰 세션은 서버 재시작 후 자동 재연결된다. 같은 세션 ID가 재스폰된다.
- worktree 스폰 세션만 tombstone된다. 재시작 후 재스폰되지 않고 원격 메시지가 로컬에
  도달하지 않는 hang 상태가 된다.
- tombstone 복구: 해당 worktree에서 `claude remote-control --session-id <cse_...>`를
  실행하면 pending 프롬프트까지 처리된다.
- 복구 프로세스도 cwd 기준 환경을 하나 등록한다. worktree 경로가 환경 이름으로 목록에
  추가되는 오염 부작용이 있으므로 필요한 경우에만 쓴다.
- claude.ai/모바일 앱 환경 상세의 "N 중 M" 탭에는 "세션 종료" UI가 있어 capacity 슬롯을
  직접 해제할 수 있다.
- 서버는 네트워크 약 10분 단절 시 자기 종료한다. 30분 ensure가 부활을 담당한다.
- 서버 종료 시 정상 종료와 kill 모두 자식 세션 프로세스를 함께 정리한다.

## 기존 tmux bridge에서 마이그레이션

구 tmux 기반 bridge가 같은 디렉토리에서 아직 떠 있으면 새 `claude-rc-maint`는
`unmanaged-server-present`로 기동을 거부한다. 같은 디렉토리에 두 번째 서버를 띄우면
삭제 불가능한 유령 환경이 생기므로, 이 거부가 정상 안전장치다.

절차:

```bash
tmux kill-session -t claude-rc
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
pgrep -fl 'claude remote-control'
```

NixOS:

```bash
journalctl -u claude-rc-ensure --since -2d
systemctl list-timers claude-rc-ensure
systemctl start claude-rc-ensure
```

macOS:

```bash
launchctl list | grep claude-rc
launchctl print "gui/$(id -u)/org.nix-community.home.claude-rc-ensure"
tail -50 ~/Library/Logs/claude-rc-ensure.log
launchctl kickstart "gui/$(id -u)/org.nix-community.home.claude-rc-ensure"
```

| status action | 의미 / 조치 |
|---------------|-------------|
| `no-instances` | 등록된 인스턴스 없음. `claude-rc start` 또는 선언 env 확인 |
| `path-missing` | 등록 경로가 없음. 등록은 유지되며 알림 대상 아님. stale 등록이면 아래 flock+jq 예시로 제거 |
| `started` | 죽은 인스턴스를 시작함 |
| `healthy` | 실행 버전과 desired 버전 일치 |
| `restarted-version-drift` | version drift 재시작 완료 |
| `deferred-active-sessions` | worktree 세션 활동 감지로 재시작 유예 |
| `deferred-unknown-activity` | 세션 프로세스는 있으나 transcript 명명 매치가 없어 보수 유예 |
| `start-failed` / `restart-failed` | `<slug>/server.log` 확인 |
| `unmanaged-server-present` | 같은 cwd의 unmanaged 서버 감지. legacy tmux bridge 잔존 포함. 기존 서버 종료 후 `claude-rc start` 또는 다음 ensure |
| `no-server-process` | lock은 잡혔지만 cwd가 같은 서버 PID를 못 찾음. stale lock 또는 프로세스 shape 확인 |
| `running-version-unresolvable` | 실행 바이너리 경로 조회 실패. `lsof`/`/proc` 접근 확인 |
| `declared-instances-invalid` | `CLAUDE_RC_DECLARED_INSTANCES` JSON/경로/spawn/capacity 오류 |
| `lock-acquire-timeout` | ensure 중복 실행 또는 lock fd 누수 의심 |

stale 등록 수동 제거:

```bash
STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
path="/path/to/project"
(
  flock 8
  tmp=$(mktemp "$STATE_DIR/instances.XXXXXX")
  jq --arg path "$path" 'del(.instances[$path])' "$STATE_DIR/instances.json" >"$tmp"
  mv "$tmp" "$STATE_DIR/instances.json"
) 8>"$STATE_DIR/instances.json.lock"
```

증상별 조치:

| 증상 | 조치 |
|------|------|
| `claude-rc start`가 "이미 실행 중" 출력 | 정상 멱등. 옵션 변경은 `claude-rc stop` 후 재시작 |
| "same-dir claude remote-control process already exists" | 래퍼 우회 기동 감지. 기존 순정 서버 종료 후 래퍼로 시작 |
| worktree 세션이 응답 없음 | tombstone 가능성. 해당 worktree에서 `claude remote-control --session-id <cse_...>` |
| capacity 부족 | claude.ai/모바일 앱 환경 상세의 "세션 종료" UI로 슬롯 해제 |
| 서버가 주기적으로 사라짐 | 네트워크 단절 자기 종료 가능. 다음 ensure 주기와 `server.log` 확인 |

## 관련 파일

- 래퍼: `modules/nixos/scripts/claude-rc.sh`
- 래퍼 패키지: `modules/nixos/lib/claude-rc-package.nix`
- maint 엔진: `modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh`
- maint 패키지: `modules/nixos/lib/claude-rc-maint-package.nix`
- NixOS systemd 배선: `modules/nixos/programs/claude-remote-control.nix`
- macOS launchd 배선: `modules/darwin/programs/claude-remote-control.nix`
- NixOS 옵션: `modules/nixos/options/homeserver.nix`
- NixOS Home Manager 래퍼 링크: `modules/shared/programs/shell/nixos.nix`
- 테스트: `tests/suites/claude-remote-control.sh`
