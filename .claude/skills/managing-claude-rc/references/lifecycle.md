# 상태와 세션 수명주기

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
- ensure 로그: ensure 실행별 진단 로그. `no-server-process` 판정의 탈락 술어(`scan-rejects`)가
  여기에만 남는다 (#1275). macOS는 파일 로그(`~/Library/Logs/claude-rc-ensure.log`,
  `CLAUDE_RC_ENSURE_LOG`)이며 `server.log`와 같은 5MB 임계로 `.1` 1세대 rotate된다.
  NixOS는 이 변수를 주지 않으므로 journald가 보관한다 (`journalctl -u claude-rc-ensure`)
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
resolved target은 `VERSIONS_DIR`(기본
`~/.local/share/claude/versions`) 아래여야 하고, 실제 bridge executable은 그 아래이거나
그 아래 항목과 같은 파일(dev:ino 동일)이어야 하며, `desiredVersion`은 resolved executable의
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

## 환경과 세션 수명주기

아래 수명주기와 Issue #1093의 C no-grant matrix는 당시 지원 버전에서 실측했다. Claude Code
또는 launcher identity가 바뀌면 현재 version을 repo에 고정 기록하지 말고
`../../managing-macos/references/tcc.md`의 update matrix를 다시 실행한다.

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
  `~/.local/share/claude/versions`) 아래이거나 그 아래 항목과 같은 파일(dev:ino
  동일)일 것도 요구한다 — argv 문자열만 일치하는 무관 프로세스의 오탐 방지
  (#1060). 경로 문자열이 아니라 동일성으로 판정하는 이유는 Darwin의 exe 경로가
  vnode에 캐시된 이름 하나여서 하드링크 별칭이 있으면 흔들리기 때문이다. 같은
  이유로 flock launcher 판정도 store 경로 패턴과 dev:ino 동일성을 함께 본다. lifecycle signal 대상은 여기에 exact
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
- guardian 테스트: `tests/suites/claude-remote-control-guardian.sh` — 12개 `test_*` 함수가 `tests/shell-script-tests.sh`에 등록되어 `tests/run-all-tests.sh`에서 호출된다. 정의·등록 일치는 `test_suite_function_registration_parity`가 검사한다. 플랫폼 전용 검사는 해당 플랫폼에서만 수행한다.
- maint/status 테스트: `tests/suites/claude-remote-control-maint.sh`
