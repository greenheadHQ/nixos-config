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
| `claude-rc cleanup` | git worktree 등록이 끊긴 `.claude/worktrees/*` 잔해만 삭제. 등록된 worktree는 죽은 세션의 것이라도 비대상 — `wt cleanup` 사용 (잠긴 worktree는 `git worktree unlock` 선행) |

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

## 필요한 문서 선택

| 작업 | 참조 |
|------|------|
| 설정·ensure·프로세스 식별·세션 수명주기 조사 | [lifecycle.md](references/lifecycle.md) |
| 재시작·tmux 마이그레이션 | [recovery.md](references/recovery.md) |
| action 코드·tombstone 복구·상태 게시 실패·장애 증상 해석 | [troubleshooting.md](references/troubleshooting.md) |

## 운영 경계

- 한 디렉터리에 bridge 하나만 둔다. `pgrep`만으로 관리 대상을 판정하거나 식별 불가 PID를 signal하지 않는다.
- 재시작은 same-dir 작업 유실과 worktree 세션 tombstone을 유발할 수 있다. 실행 전에 recovery 문서의 exact path·version 및 작업 직전 승인 계약을 적용한다.
- macOS periodic ensure는 죽은 bridge만 복구하고 live drift를 보존한다. NixOS 수동 ensure는 재시작까지 할 수 있으므로 lifecycle/recovery 계약을 먼저 확인한다.
- `source=declared`는 다음 ensure가 선언값으로 되돌린다. 지속 중지·옵션 변경은 Nix 선언에서 한다.
- `cleanup`은 Git 등록이 끊긴 잔해만 대상으로 한다. 등록된 worktree·dirty/unpushed 작업·live lock을 우회하지 않으며 lock 해제 확인 전 정리 성공을 주장하지 않는다.
- status 파일은 과거 snapshot이다. 현재 생존은 `claude-rc ls`로 판별한다.
- persistent root는 `~/Workspace`다. 보호 폴더는 활성 세션의 `/add-dir` opt-in으로 접근하며 선언 launcher에 임의 `--add-dir`를 넣지 않는다.

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
