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
| `claude-rc stop [path]` | 현재 또는 지정 절대경로 인스턴스 서버 종료 및 등록 해제. worktree 세션 존재 시 `--force` 필요 |
| `claude-rc ls` | 등록 인스턴스, 실행 여부, PID, 버전, spawn, source, 로그 경로 출력 |
| `claude-rc cleanup` | git worktree 등록이 끊긴 `.claude/worktrees/*` 잔해만 삭제. 등록된 worktree는 죽은 세션의 것이라도 비대상 — `wt cleanup` 사용 |

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
6. drift가 있으면 실행 중 서버 argv의 effective spawn을 실측한다.
7. effective `spawn=same-dir`이면 즉시 재시작한다.
8. effective `spawn=worktree` 또는 파싱 불가이면 idle gate를 통과할 때만 재시작한다.

registry의 `spawn`은 desired state이며 부활/재기동 옵션으로만 쓴다. 재시작 안전성은
이미 실행 중인 프로세스의 실제 spawn 모드가 결정한다.

worktree idle gate:

- 최근 `IDLE_THRESHOLD_MINUTES` 내 transcript가 있으면 `deferred-active-sessions`
- `--sdk-url` 세션 프로세스는 있는데 worktree transcript 디렉토리 명명 매치가 0이면
  `deferred-unknown-activity`
- 둘 다 아니면 `restarted-version-drift`

transcript 매칭은 `<정규화된 인스턴스 경로>--claude-worktrees-*`만 본다.
인스턴스 root transcript는 로컬/same-dir 세션 활동일 수 있어 worktree drift gate에
포함하지 않는다.

## 환경과 세션 수명주기

실측 기준: Claude Code v2.1.204–2.1.205.

- 서버 1개 = claude.ai 환경 1개.
- 환경 표시명은 upstream이 호스트명 + 디렉토리 basename으로 정한다.
- 환경 회수 조건: 환경은 디렉토리 경로 기준으로 서버측에 보존되지만, 재기동이 같은
  환경을 회수하는 것은 보존된 세션이 1개 이상 있을 때만이다 (종료 시
  "Environment preserved" 메시지도 이 경우에만 출력). 세션 0개인 서버의 재기동은
  매번 새 환경을 만들고 이전 항목은 비활성으로 목록에 남는다.
  - 함의: 상시 인스턴스(`--no-create-session-in-dir`)는 세션이 없는 동안의 재시작
    (버전 drift 등)마다 목록에 비활성 항목을 남긴다. 세션 손실이 없는 정상 동작이며
    실해는 목록 노이즈뿐이다.
- 같은 디렉토리에 서버 2개가 동시에 뜨면 두 번째가 새 환경을 만든다. 유령(비활성)
  환경은 삭제 UI가 없고 죽은 직후 온라인으로 보일 수 있으나, 보존 세션 유무와 무관하게
  수 시간 내 목록에서 자연 소멸한다 (실측: 서버 종료 40분 시점에는 잔존, 6시간 시점에는
  전부 소멸). 목록 노이즈는 자가 치유되므로 별도 조치가 필요 없다.
- 중복 기동 방지는 래퍼의 `flock` + cwd 실측 가드가 유일한 방어다. 실측 가드의
  서버 판정은 cwd 외에 실행 바이너리가 claude 배포 경로(`VERSIONS_DIR`, 기본
  `~/.local/share/claude/versions`) 아래인지도 요구한다 — argv 문자열만 일치하는
  무관 프로세스의 오탐 방지 (#1060).
- same-dir 스폰 세션은 서버 재시작 후 자동 재연결된다. 같은 세션 ID가 재스폰되고
  대화는 보존된다. 단 실행 중이던 백그라운드 작업/도구 프로세스는 유실된다 —
  프로세스가 서버와 함께 죽고 재스폰 세션의 작업 레지스트리도 초기화된다. 앱 UI는
  재시작 직후 stale "실행 중" 표시를 유지하다가 다음 상호작용 때 "중지됨"으로
  동기화되며, 완료 알림은 오지 않는다.
- worktree 스폰 세션만 tombstone된다. 재시작 후 재스폰되지 않고 원격 메시지가 로컬에
  도달하지 않는 무한 hang 상태가 된다. 서버 자체가 죽은 경우와 증상이 다르다 —
  서버 사망은 앱이 "원격 제어 연결 끊김" 에러 카드로 감지·표시한다.
- tombstone 복구: 해당 worktree에서 `claude remote-control --session-id <cse_...>`를
  실행하면 pending 프롬프트까지 처리된다.
- 복구 프로세스도 cwd 기준 환경을 하나 등록한다. worktree 경로가 환경 이름으로 목록에
  추가되는 오염 부작용이 있으므로 필요한 경우에만 쓴다.
- claude.ai/모바일 앱 환경 상세의 "N 중 M" 탭에는 "세션 종료" UI가 있어 capacity 슬롯을
  직접 해제할 수 있다.
- capacity는 소프트 리밋이다. 서버가 세션 N개를 보존한 상태에서 더 작은 `--capacity`로
  재기동하면 오버부킹(세션 수 > capacity)이 성립하고 환경 목록에 주황색 "N개 중 M개"로
  경고 표시된다. 만석/초과 상태에서 앱의 새 대화로 프롬프트를 보내면 에러 없이 기존
  활성 세션으로 조용히 라우팅된다 — 새 세션이라 생각한 프롬프트가 기존 대화에 섞이는
  함정에 주의.
- 서버는 네트워크 약 10분 단절 시 자기 종료한다. 30분 ensure가 부활을 담당한다.
- 서버가 정상 종료(SIGTERM/Ctrl-C)하면 자식 세션 프로세스를 함께 정리한다. SIGKILL로
  죽으면 자식이 고아(ppid=1)로 잔존한다 (ensure의 고아 정리는 #1061).

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
| `path-missing` | 등록 경로가 없음. 등록은 유지되며 알림 대상 아님. stale 등록이면 `claude-rc stop /path/to/project`로 제거 |
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

증상별 조치:

| 증상 | 조치 |
|------|------|
| `claude-rc start`가 "이미 실행 중" 출력 | 정상 멱등. 옵션 변경은 `claude-rc stop` 후 재시작 |
| "same-dir claude remote-control process already exists" | 래퍼 우회 기동 감지. 기존 순정 서버 종료 후 래퍼로 시작 |
| worktree 세션이 응답 없음 | tombstone 가능성. 해당 worktree에서 `claude remote-control --session-id <cse_...>` |
| capacity 부족 | claude.ai/모바일 앱 환경 상세의 "세션 종료" UI로 슬롯 해제 |
| 서버가 주기적으로 사라짐 | 네트워크 단절 자기 종료 가능. 다음 ensure 주기와 `server.log` 확인 |
| 죽은 bridge 세션의 worktree/브랜치 잔존 | `claude-rc cleanup`은 git 등록된 worktree를 지우지 않는다. `wt ls`로 이름·dirty/unpushed 확인 후 `wt cleanup <name> [--yes]`로 정리 |

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
