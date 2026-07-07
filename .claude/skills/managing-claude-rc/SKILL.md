---
name: managing-claude-rc
description: |
  Manage Claude Code Remote Control bridge (claude-rc): 기전, 세션 수명주기, 자동 재시작, 트러블슈팅.
  Trigger: 'claude-rc', 'remote control', '리모트 컨트롤', 'bridge 서버', '모바일 세션',
  'claude-rc-ensure', 'claude-rc-maint', '세션 tombstone', 'bridge 재시작'.
  NOT for Codex remote control (use configuring-codex / issuing-codex-pairing-code).
  NOT for tmux 일반 설정 (use managing-tmux).
---

# Claude Code Remote Control (claude-rc) 관리

Claude 모바일 앱/claude.ai에서 MiniPC의 Claude Code 세션을 원격 조종하는
bridge 서버의 운영 가이드. NixOS(MiniPC) 전용 — macOS/darwin 배포는 별도 이슈 범위.

## 기전 (3계층)

```text
tmux 세션 "claude-rc" (detached 상시 구동)
 └─ claude-rc 래퍼 (modules/nixos/scripts/claude-rc.sh)
     ├─ 재시작 루프: 비정상 종료 시 exponential backoff로 자동 재시작
     ├─ stale 감지: tmux 환경변수 CLAUDE_RC_ACTIVE
     └─ claude remote-control --spawn worktree --no-create-session-in-dir ...
         └─ 모바일에서 새 세션 요청 시:
             .claude/worktrees/bridge-cse_<세션ID> git worktree 생성 (locked) 후
             `claude --print --sdk-url https://api.anthropic.com/v1/code/sessions/cse_...`
             자식 프로세스 스폰 (outbound 연결만 사용, 인바운드 포트 없음)
```

- transcript는 `~/.claude/projects/<정규화된 경로>/<uuid>.jsonl`에 기록된다.
  프로젝트 디렉토리명은 경로의 비영숫자가 하이픈으로 정규화된다
  (예: `bridge-cse_01AB...` worktree → `...--claude-worktrees-bridge-cse-01AB...`).

## 사용자 래퍼 (claude-rc)

| 명령 | 동작 |
|------|------|
| `claude-rc` | 서버 시작 + tmux attach |
| `claude-rc --detach` | 서버 시작 (백그라운드) |
| `claude-rc --attach` | 기존 세션 접속 |
| `claude-rc --stop` | 서버 종료 (활성 세션 tombstone — 아래 수명주기 참조) |
| `claude-rc --cleanup` | 서버 종료 + worktree prune + orphan 디렉토리 삭제 |

옵션: `--permission-mode <mode>`, `--capacity <N>`, `--name <name>`.
수동 실행 시에도 **NixOS 선언값(`homeserver.claudeRemoteControl.*`)과 일치시켜야**
자동 재시작 후 동작이 달라지지 않는다.

## 자동 재시작 (claude-rc-ensure timer)

`homeserver.claudeRemoteControl.enable = true` 시 systemd timer가 부팅 2분 후 +
30분마다 `claude-rc-maint ensure`를 실행한다
(`modules/nixos/programs/claude-remote-control.nix`).

판정 흐름:
1. tmux 세션 부재/stale → bridge 시작 (부팅 후 자동 복구 겸함)
2. 실행 중 bridge의 `/proc/PID/exe` 버전 vs `readlink -f ~/.local/bin/claude` 비교
3. drift 없음 → healthy
4. drift 있음 → idle 게이트:
   - 최근 `IDLE_THRESHOLD_MINUTES`(기본 30분) 내 활동한 bridge transcript가 있으면 유예
   - 스폰 세션 프로세스가 있는데 transcript 명명 규칙 매치가 전혀 없으면
     판정 불가로 보수적 유예 (`deferred-unknown-activity`)
   - 둘 다 아니면 재시작 (`restarted-version-drift`)
5. 모든 경로에서 status 기록 + Pushover 알림 (상태 전이 기반, cooldown 30분)

운영 옵션(permissionMode/capacity/name)은 nix 옵션으로 선언되어 재시작 시 보존된다:
`hosts` 설정은 `modules/nixos/configuration.nix`의 `homeserver.claudeRemoteControl` 블록.

Pushover fallback: 크리덴셜(`pushover-system-monitor.age`, minipcOnly)이 없는 호스트에서
maint를 수동 실행하면 알림만 스킵되고 ensure 본체는 정상 동작한다.
systemd 유닛은 `ConditionPathExists`로 credential 부재 시 조용히 skip된다 (agenix 장애 신호).

## 세션 수명주기 (중요)

- disconnect ≠ end session: 모바일 앱 연결을 끊어도 세션 프로세스는 계속 살아
  capacity 슬롯을 점유한다. upstream에 세션 age-out이 없다 (#60568 — schema에
  sessionTimeoutSeconds만 있고 미배선; #28917 revoke, #32050 idle timeout 모두
  미구현 stale 종결). → `--cleanup` workaround가 계속 필요한 근거.
- bridge 재시작 = 활성 세션 tombstone: 앱에서 기록은 보이지만 프롬프트가
  조용히 무시된다. 대화 기록은 보존된다:
  - 로컬 재개: 해당 worktree에서 `claude --resume <uuid>`
  - 원격 재개 (claude 2.1.200+): `claude remote-control --session-id <cse_...>`
    (spawn 플래그와 병용 불가 — 세션 전용 프로세스로 떠야 함)
- 알려진 upstream 버그: 스폰 세션이 UI 선택 모델을 무시할 수 있음 (#74049, OPEN).

## 트러블슈팅

```bash
# ensure 상태/이력
cat ~/.local/state/claude-rc/status.json
journalctl -u claude-rc-ensure --since -2d
systemctl list-timers claude-rc-ensure

# bridge 실체 확인
tmux has-session -t claude-rc && tmux attach -t claude-rc   # 래퍼 로그 확인
pgrep -af 'claude remote-control'
readlink /proc/<PID>/exe    # 실행 중 바이너리 버전

# 수동 ensure (drift 즉시 확인)
systemctl start claude-rc-ensure
```

| 증상 | 원인/조치 |
|------|----------|
| status.json `action: deferred-active-sessions` | 활성 세션 존재 — 정상 유예. 다음 주기 재시도 |
| `action: deferred-unknown-activity` | transcript 명명 규칙 drift 의심 — `claude-rc-maint.sh`의 `BRIDGE_TRANSCRIPT_GLOBS` 갱신 검토 |
| `action: no-bridge-process` | 래퍼 backoff 루프가 재시작 중 — 지속되면 `tmux attach -t claude-rc`로 루프 로그 확인 |
| unit이 실행 안 됨 (Condition failed) | `/run/agenix/pushover-system-monitor` 부재 — agenix 상태 확인 |
| capacity 꽉 참 (앱에서 새 세션 불가) | idle 프로세스가 슬롯 점유 — 앱에서 "세션 종료" 또는 `claude-rc --cleanup` |
| 모바일 세션이 응답 없음 (기록만 보임) | tombstone — 위 재개 경로 사용 |

## 관련 파일

- 래퍼: `modules/nixos/scripts/claude-rc.sh` (store 패키지: `modules/nixos/lib/claude-rc-package.nix`)
- maint 엔진: `modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh`
- systemd 모듈: `modules/nixos/programs/claude-remote-control.nix`
- 옵션: `modules/nixos/options/homeserver.nix` (`claudeRemoteControl.*`)
- HM 배선: `modules/shared/programs/shell/nixos.nix`
