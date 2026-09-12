# 상태 코드와 장애 진단

## Action 코드

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
| `no-server-process` | lock은 잡혔지만 cwd가 같은 서버 PID를 못 찾음. ensure 로그의 `scan-rejects` 라인에서 탈락 술어(cwd/exe/lineage/lock)를 먼저 확인한다 — 죽은 lock이면 다음 ensure가 재시작한다. `versions_exe`와 `parent_flock_exe` 탈락은 실행 바이너리 경계 판정이며, Darwin 하드링크 별칭으로 인한 오탐은 양쪽 모두 dev:ino 동일성 판정으로 해소됐다(아래 별칭 항목). flock 쪽 별칭은 `nix.optimise`가 동일 내용 store 파일을 합칠 때 생긴다 |
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
| ensure 로그의 `WARN: exe 경로가 VERSIONS_DIR 밖 하드링크 별칭으로 보고됨` | 실패가 아니다. macOS `lsof`가 vnode에 캐시된 이름 하나만 주므로, 실행 바이너리에 `VERSIONS_DIR` 밖 하드링크(설치 프로그램이 만드는 `ClaudeCode.app/Contents/MacOS/claude`)가 있으면 그 경로가 보고된다. dev:ino 동일성 판정이 흡수하므로 조치는 불필요하고, 별칭 상태가 바뀔 때만 한 줄 남는다. 별칭 자체를 없애려면 bridge를 링크 수 1인 최신 버전으로 재시작한다 |
| 죽은 bridge 세션의 worktree/브랜치 잔존 | `claude-rc cleanup`은 git 등록된 worktree를 지우지 않는다. `wt ls`로 이름·dirty/unpushed와 함께 `🔒`(잠김)·`⚠️ BROKEN`(디렉토리 소실 등) 표시를 확인한다. 잠기지 않았으면 `wt cleanup <name> [--yes]`. 잠긴 항목은 `wt`가 `--yes`로도 지우지 않는다 — bridge 프로세스가 잠근 것이므로 그 프로세스가 죽었는지 확인한 뒤 `git worktree unlock <path>`를 먼저 하고, 디렉토리가 이미 없으면 unlock 후 `git worktree prune`, 남아 있으면 unlock 후 `wt cleanup <name>` |
