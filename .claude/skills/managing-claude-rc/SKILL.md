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
| `claude-rc stop [path]` | 현재 또는 지정 절대경로 인스턴스 서버 종료 및 등록 해제. worktree 세션 존재 시 `--force` 필요. `source=declared`는 다음 ensure까지만 임시 중지 |
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
`source=manual`은 `claude-rc stop` 후 다시 시작한다. `source=declared`는 CLI 변경이나
`stop`을 다음 ensure가 선언값으로 되돌린다(macOS는 최대 1분). 옵션은 Nix 선언에서 바꾸고
`nrs`로 적용한다. 지속 중지는 먼저 Nix에서 ensure agent/timer를 disable해 적용한 뒤
`claude-rc stop`을 실행한다. wrapper 자체에는 pause 명령이 없다.

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
- `ensure.lock`: maint `ensure`와 interactive `start`/`stop`의 PID 판정, signal,
  launch 검증, registry 변경 전체를 직렬화한다. `ls`/`cleanup`은 비대상이다.
- `server.log`: 서버 stdout/stderr. 5MB 초과 시 1세대 rotate
- `status.json`: 마지막 ensure 실행 결과. top-level timestamp/exitCode/action과
  인스턴스별 `{path,processState,runningVersion,observedVersion,desiredVersion,action}`
  배열을 기록한다. `runningVersion`은 verified live process 전용이고,
  `observedVersion`은 종료된 mismatch를 포함한 마지막 식별 버전이다.

## 자동화

| 플랫폼 | 자동화 | 선언 위치 |
|--------|--------|-----------|
| NixOS | systemd timer `claude-rc-ensure` 30분 주기 | `homeserver.claudeRemoteControl.*` |
| macOS | launchd agent `claude-rc-ensure` 1분 주기 | `modules/darwin/programs/claude-remote-control.nix` 상수 |

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

maint의 `CLAUDE_BIN`은 launcher override이며 basename이 `claude`일 필요는 없다. 다만
resolved target과 실제 bridge executable은 `VERSIONS_DIR`(기본
`~/.local/share/claude/versions`) 아래여야 하고, `desiredVersion`은 resolved executable의
basename이다. maint는 ensure 시작 전에 두 경로를 canonicalize하고 경계를 확인한 뒤 symlink가
아닌 검증된 target을 실행한다. interactive `claude-rc start`는 자기 PATH의 literal `claude`를 사용하며 ambient
`CLAUDE_BIN`은 의도적으로 무시한다.

ensure 판정 흐름:

1. 선언 인스턴스가 `instances.json`에 없으면 `source=declared`로 추가한다.
2. 인스턴스 경로가 없고 instance lock이 비어 있으면 `path-missing`으로 기록하고 등록은 유지한다.
   경로는 없지만 lock이 잡혀 있으면 live orphan 가능성을 숨기지 않고
   `path-missing-lock-held`/`processState=unknown`으로 실패한다.
3. lock이 비어 있으면 서버를 headless로 시작한다.
4. 살아 있으면 실행 중 바이너리 버전과 desired Claude launcher 버전을 비교한다.
5. drift가 없으면 `healthy`.
6. drift가 있고 `CLAUDE_RC_DRIFT_POLICY=defer`이면 live bridge를 그대로 두고
   `deferred-restart-confirmation`을 기록한다. macOS periodic ensure가 이 정책을 쓴다.
7. `confirmed`이면 lifecycle lock 안의 전체 drift tuple이 non-empty approval JSON과 exact match해야 한다.
8. `automatic` 또는 validated `confirmed`이면 실행 중 서버 argv의 effective spawn을 실측한다.
9. effective `spawn=same-dir`이면 즉시 재시작한다.
10. effective `spawn=worktree` 또는 파싱 불가이면 idle gate를 통과할 때만 재시작한다.

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

## macOS TCC 운영 경계

Issue #1093의 Remote Control 전용 결론은 persistent root를 `~/Workspace`로 유지하고 보호
폴더는 활성 session의 `/add-dir`로 opt-in하는 것이다. `claude-rc` wrapper는 `--add-dir`를
전달하지 않으므로 declared launcher argv에 임의로 추가하지 않는다. macOS periodic ensure는
죽은 bridge를 1분 안에 자동 복구하지만 live version drift는
`deferred-restart-confirmation`으로 유지한다. bridge 재시작은 worktree session을 tombstone시킬
수 있어 action-time confirmation 없이 수행하지 않는다.

TCC grant 경계, `/add-dir` deadline과 원격 복구, launcher identity, A/B/PPPC 판단,
no-grant matrix, 적용·rollback은 단일 운영 SoT인
[`managing-macos/references/tcc.md`](../managing-macos/references/tcc.md)를 따른다. 특히
[`C: Workspace-only와 보호 폴더 opt-in`](../managing-macos/references/tcc.md#c-workspace-only와-보호-폴더-opt-in)과
[`/add-dir deadline 경계와 원격 복구`](../managing-macos/references/tcc.md#add-dir-deadline-경계와-원격-복구)를
먼저 확인한다.

## 환경과 세션 수명주기

아래 수명주기와 Issue #1093의 C no-grant matrix는 당시 지원 버전에서 실측했다. Claude Code
또는 launcher identity가 바뀌면 현재 version을 repo에 고정 기록하지 말고
`../managing-macos/references/tcc.md`의 update matrix를 다시 실행한다.

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
  나중에 목록에서 자연 소멸한다. 목록 노이즈는 자가 치유되므로 별도 조치가 필요 없다.
- 중복 기동 방지는 래퍼의 `flock` + cwd 실측 가드가 유일한 방어다. maint의 configurable
  launcher basename은 `claude`일 필요가 없다. 후보 수집은 공식 `remote-control`/`rc` 형태를
  넓게 찾고 exact command token을 요구한다. self-updating CLI의 global-option 문법은 복제하지
  않는다. `-p`/`--print`/`--` 뒤 token은 prompt data로 제외하되, 그 밖의 모호한 같은-cwd
  versioned candidate는 signal하지 않고 새 서버 시작만 보수적으로 차단한다. 서버 판정은 cwd 외에
  실행 바이너리가 claude 배포 경로(`VERSIONS_DIR`, 기본
  `~/.local/share/claude/versions`) 아래인지도 요구한다 — argv 문자열만 일치하는
  무관 프로세스의 오탐 방지 (#1060). lifecycle signal 대상은 여기에 exact
  `remote-control`/`--no-create-session-in-dir` argv token, immutable Nix-store의
  discoteq/util-linux `flock` direct parent, exact `flock -n <instance-lock> <Claude bridge>`
  argv, parent/child가 함께 연 busy instance lock까지 요구한다. 현재 PATH target만 pin하지
  않고 이전 Nix generation의 flock도 받아 update 중인 bridge를 식별한다. 같은 cwd/version의
  argv 비교는 Linux `/proc/<pid>/cmdline`, Darwin `KERN_PROCARGS2`를 쓰는 bundled helper로 실제
  argument 경계를 보존한다. 공백으로 평탄화된 `ps command`를 exact token 증거로 사용하지 않는다.
  별도 bridge가 있어도 이 lock lineage가 없으면 `no-server-process`로 fail closed한다. signal 뒤에는
  child 소멸과 parent flock의 FD close 사이 race를 bounded poll로 흡수한다. 새 launcher guardian은
  caller decision까지 살아 있어 PID 재사용 signal을 막고, native supervisor가 별도 process group의
  stable leader로 남아 조기 종료한 `flock`의 reparented descendant도 같은 group 안에서 정리한다.
  cancel/handoff acknowledgment와 fallback cleanup은 모두 deadline을 둔다. fallback은 exact
  guardian→group-leader PPID와 PGID를 freeze/revalidate하며, lock-free postcondition 전에는 global
  `stopped`를 주장하지 않는다. descendant가 의도적으로 `setpgid`/`setsid`로 이 경계를 벗어나 lock을
  계속 보유하면 cleanup 성공이 아니라 `unknown`으로 fail closed한다 (#1093).
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
- 서버는 네트워크 약 10분 단절 시 자기 종료할 수 있다. macOS는 login 직후 transient
  종료도 실제 관측됐으므로 1분 ensure가 부활을 담당한다. 성공한 ensure 결과는
  `status.json` top-level `.action == "completed"`와 대상 `.instances[]`의
  성공 action, `.processState == "running"`, non-empty `.runningVersion`을 함께
  확인한다. 성공 action은 정책별로 다르다: 정상 경로는 `"started"`/`"healthy"`,
  NixOS의 자동 drift 재시작은 `"restarted-version-drift"`, macOS의 의도적 보류는
  `"deferred-restart-confirmation"`/`"deferred-active-sessions"`/`"deferred-unknown-activity"`로
  기록된다 (실패만 `"failed"`). `started`/`healthy`만 성공으로 보면 drift 재시작과
  defer를 실패로 오판한다. `.observedVersion`은 마지막으로 식별한 버전이라
  이미 멈춘 mismatch process에도 남을 수 있다. `.runningVersion`은 각 instance 처리 시점에
  live identity를 검증했을 때만 채우지만, top-level timestamp를 쓰기 직전에 모든 instance를
  다시 검증하지는 않는다. 따라서 현재 생존 여부는 별도로 `claude-rc ls`의 `RUNNING=yes`와
  `VERSION` 열을 확인한다.
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
    | {path, runningVersion, desiredVersion,
       runningEnvironmentGeneration, desiredEnvironmentGeneration}]
    | sort_by([.path, .runningVersion, .desiredVersion,
               .runningEnvironmentGeneration, .desiredEnvironmentGeneration])' "$status"
)"
jq -e 'length > 0' <<<"$approval" >/dev/null
jq -r '.[] | [.path, .runningVersion, .desiredVersion,
               .runningEnvironmentGeneration, .desiredEnvironmentGeneration] | @tsv' <<<"$approval"
claude-rc ls
```

block 전체가 exit 0일 때만 출력된 후보를 승인 목록으로 쓴다. 후보 전체를 이름으로 포함해
action-time confirmation을 한 번 받고 처음의 exact JSON을 stable home symlink maint에 전달한다.
Darwin의 managed launcher에서는 environment generation까지 포함한 5-field tuple이 필수다.
`confirmed`는 lifecycle lock을 잡은 뒤 현재
`(path,runningVersion,desiredVersion,runningEnvironmentGeneration,desiredEnvironmentGeneration)` 집합을
다시 계산해 approval과 exact match하는 경우만 restart한다. 어느 명령이나 status 검증이 실패하거나
runtime snapshot이 달라졌으면 restart하지 않고 새 `defer` snapshot으로 승인부터 다시 수행한다.
one-shot policy/approval env는 새 bridge에 상속되지 않는다.

```bash
CLAUDE_RC_DRIFT_POLICY=confirmed \
CLAUDE_RC_DRIFT_APPROVAL_JSON="$approval" \
  claude-rc-maint ensure
```

### Top-level `status.action`

`none`과 `running`은 실행 중에만 쓰는 internal 값이며 final status vocabulary에 포함하지 않는다.

| top-level action | 의미 / 조치 |
|------------------|-------------|
| `flock-missing` | lifecycle 직렬화 도구가 없음. 배포 package/PATH가 current generation과 일치하는지 확인 |
| `lock-acquire-timeout` | 다른 ensure 또는 interactive start/stop이 lifecycle 변경 중이거나 lock fd 누수 의심 |
| `lock-setup-failed` | lifecycle lock parent 생성 또는 lock file open 실패. state path node type·mode·filesystem 상태 확인 |
| `declared-instances-invalid` | `CLAUDE_RC_DECLARED_INSTANCES` JSON/경로/spawn/capacity 오류 |
| `invalid-drift-policy` | `CLAUDE_RC_DRIFT_POLICY`가 `automatic`/`confirmed`/`defer`가 아님. launcher environment 확인 |
| `invalid-drift-approval` | confirmed JSON이 malformed/empty이거나 locked runtime drift 집합과 다름. 새 `defer` snapshot으로 다시 확인 |
| `desired-version-unresolvable` | canonical launcher가 없거나 실행 불가하거나 `VERSIONS_DIR` 밖임. stable launcher symlink와 version directory 확인 |
| `instances-read-failed` | registry lock/read/parse 실패. `instances.json` type·mode와 lock owner 확인 |
| `no-instances` | 등록된 인스턴스 없음. `claude-rc start` 또는 선언 env 확인 |
| `completed` | 모든 instance 처리가 성공함. 각 `instances[].action`에서 세부 결과 확인 |
| `failed` | 하나 이상의 instance 처리가 실패함. 각 failure action과 exact lock/process identity 확인 |

### Status publication failure

`status-write-failed`는 `status.json.action` 값이 아니다. final status 게시 자체가 실패한 뒤에만 정해지는
진단값이므로 새 JSON에 기록할 수 없다. 이 경우 command는 nonzero로 끝나고 stderr·notification에는
`status-write-failed`가 남으며, 기존 `status.json`은 없거나 stale일 수 있다. state directory
mode·node type·filesystem 상태를 확인하고 command exit와 log를 status 파일보다 우선한다.

### Per-instance `status.instances[].action`

| instance action | 의미 / 조치 |
|-----------------|-------------|
| `path-missing` | 등록 경로가 없음. 등록은 유지되며 알림 대상 아님. stale 등록이면 `claude-rc stop /path/to/project`로 제거 |
| `path-missing-lock-held` | 등록 경로는 사라졌지만 instance lock이 살아 있음. `processState=unknown` 실패로 기록하며, lock owner와 bridge identity를 읽기 전용으로 확인한 뒤 recovery는 action-time confirmation을 받음 |
| `started` | 죽은 인스턴스를 시작하고 실제 server PID/version까지 확인한 ensure 실행 시점 snapshot. 현재 생존을 보장하지 않으므로 `claude-rc ls`도 확인 |
| `healthy` | 실행 버전과 desired 버전 일치 |
| `restarted-version-drift` | version drift 재시작 완료 |
| `deferred-restart-confirmation` | macOS liveness-only ensure가 live version drift를 보존함. 전체 tuple의 action-time confirmation 뒤 `confirmed` policy와 exact approval JSON으로 재실행 |
| `restart-approval-mismatch` | lifecycle lock 이후 runtime tuple이 confirmed JSON과 달라 restart하지 않음. 새 `defer` snapshot으로 승인부터 다시 수행 |
| `deferred-active-sessions` | worktree 세션 활동 감지로 재시작 유예 |
| `deferred-unknown-activity` | 세션 프로세스는 있으나 transcript 명명 매치가 없어 보수 유예 |
| `restart-gate-failed` | worktree 재시작 activity gate 자체를 평가하지 못함. live bridge는 유지하고 transcript/session process 조회 실패를 확인 |
| `start-failed` | launcher 호출/guardian handshake를 확인하지 못함. `processState=unknown`; `<slug>/server.log`, exact launcher와 lock owner를 확인하고 macOS는 다음 1분 ensure에서 재시도 |
| `invalid-spawn` | 등록된 instance의 spawn 값이 `worktree`/`same-dir`가 아님. 선언과 registry를 확인 |
| `invalid-capacity` | 등록된 capacity가 음이 아닌 정수가 아님. 선언과 registry를 확인 |
| `invalid-permission-mode` | 등록된 permission mode가 지원 목록에 없음. 선언과 registry를 확인 |
| `restart-failed` | 기존 server stop/lock 해제 또는 replacement launcher/lock 획득 단계가 실패함. 현재 PID와 instance lock owner를 확인 |
| `start-version-unresolvable` | 새 server가 lock을 잡았지만 deadline 안에 full PID/version identity를 확인하지 못했고 guardian cleanup 성공도 확인하지 못함. `processState=unknown`; unknown PID를 수동 kill하지 말고 exact launcher와 lock owner를 확인 |
| `start-version-unresolvable-cleaned` | deadline 안에 full identity를 확인하지 못했지만 exact guardian-owned process group이 종료되고 instance lock 해제까지 확인됨. `processState=stopped`; 다음 ensure가 다시 시도할 수 있음 |
| `restart-version-unresolvable` | replacement가 lock을 잡았지만 deadline 안에 full PID/version identity를 확인하지 못했고 guardian cleanup 성공도 확인하지 못함. `processState=unknown`; unknown PID를 수동 kill하지 말고 exact launcher와 lock owner를 확인 |
| `restart-version-unresolvable-cleaned` | replacement의 full identity는 확인하지 못했지만 exact guardian-owned process group이 종료되고 instance lock 해제까지 확인됨. `processState=stopped`; 다음 ensure가 다시 시도할 수 있음 |
| `start-version-mismatch` | 새 server가 desired와 다른 version임을 확인했고 PID/cwd/argv/exe 재검증 뒤 종료·lock 해제함. launcher target과 배포 generation 확인 |
| `restart-version-mismatch` | replacement가 desired와 다른 version임을 확인했고 안전한 종료·lock 해제를 완료함. launcher target과 배포 generation 확인 |
| `start-version-mismatch-cleanup-failed` | start mismatch process의 action-time 재검증·TERM·lock cleanup 중 하나가 실패함. unknown PID를 수동 kill하지 말고 identity와 lock owner 확인 |
| `restart-version-mismatch-cleanup-failed` | restart mismatch process의 action-time 재검증·TERM·lock cleanup 중 하나가 실패함. unknown PID를 수동 kill하지 말고 identity와 lock owner 확인 |
| `unmanaged-server-present` | 같은 cwd의 unmanaged 서버 감지. legacy tmux bridge 잔존 포함. 기존 서버 종료 후 `claude-rc start` 또는 다음 ensure |
| `no-server-process` | lock은 잡혔지만 cwd가 같은 서버 PID를 못 찾음. stale lock 또는 프로세스 shape 확인 |
| `running-version-unresolvable` | 실행 바이너리 경로 조회 실패. `lsof`/`/proc` 접근 확인 |

증상별 조치:

| 증상 | 조치 |
|------|------|
| `claude-rc start`가 "이미 실행 중" 출력 | 정상 멱등. 옵션 변경은 `claude-rc stop` 후 재시작 |
| `/add-dir` 뒤 원격 세션이 응답 없음 | abort는 best-effort. 로컬에서 exact launcher TCC prompt를 resolve하고, 확인받은 재시작 뒤 필요하면 exact worktree에서 tombstone 복구 |
| "same-dir claude remote-control process already exists" | 래퍼 우회 기동 감지. 기존 순정 서버 종료 후 래퍼로 시작 |
| worktree 세션이 응답 없음 | tombstone 가능성. 해당 worktree에서 `claude remote-control --session-id <cse_...>` |
| capacity 부족 | claude.ai/모바일 앱 환경 상세의 "세션 종료" UI로 슬롯 해제 |
| 서버가 주기적으로 사라짐 | 네트워크 단절 자기 종료 가능. 다음 ensure 주기와 `server.log` 확인 |
| 죽은 bridge 세션의 worktree/브랜치 잔존 | `claude-rc cleanup`은 git 등록된 worktree를 지우지 않는다. `wt ls`로 이름·dirty/unpushed 확인 후 `wt cleanup <name> [--yes]`로 정리 |

## 관련 파일

- 래퍼: `modules/nixos/scripts/claude-rc.sh`
- 공유 lifecycle lib: `modules/nixos/scripts/claude-rc-lib.sh`
- 래퍼 패키지: `modules/nixos/lib/claude-rc-package.nix`
- PID argv helper: `modules/nixos/scripts/claude-rc-pid-argv.c`
- PID argv helper 패키지: `modules/nixos/lib/claude-rc-pid-argv-package.nix`
- launch-group supervisor: `modules/nixos/scripts/claude-rc-launch-group.c`
- launch-group 패키지: `modules/nixos/lib/claude-rc-launch-group-package.nix`
- 플랫폼별 flock selector: `libraries/claude-rc-flock.nix`
- maint 엔진: `modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh`
- maint 패키지: `modules/nixos/lib/claude-rc-maint-package.nix`
- NixOS systemd 배선: `modules/nixos/programs/claude-remote-control.nix`
- macOS launchd 배선: `modules/darwin/programs/claude-remote-control.nix`
- NixOS 옵션: `modules/nixos/options/homeserver.nix`
- NixOS Home Manager 래퍼 링크: `modules/shared/programs/shell/nixos.nix`
- 공통 테스트 fixture: `tests/lib/claude-remote-control-fixtures.sh`
- 래퍼 테스트: `tests/suites/claude-remote-control-wrapper.sh`
- guardian 테스트: `tests/suites/claude-remote-control-guardian.sh`
- maint/status 테스트: `tests/suites/claude-remote-control-maint.sh`
