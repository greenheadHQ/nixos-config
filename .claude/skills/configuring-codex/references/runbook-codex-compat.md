# Codex Compatibility Runbook (2026-02-08)

## 개요

- 발생 일자: 2026년 2월 8일 (Sunday)
- 대상 프로젝트: `/Users/green/Workspace/nixos-config`
- 문제 유형: Codex CLI가 global(user) 스코프 스킬은 인식하지만 project 스코프(`.agents/skills`) 스킬을 안정적으로 인식하지 못함

> 이 문서의 2026-02-08 해결 내용과 확인 결과는 당시 장애의 historical record다.
> 현재 운영 계약은 아래 재검증 섹션과 2026-02-19 이후 업데이트를 따른다.

## 2026-07-11 재검증: 현재 운영 계약

- Direct Codex의 기본 fan-out은 native subagent다. `using-codex-exec`은
  자기 참조 방지를 위해 Direct Codex에 의도적으로 노출하지 않으며 직접 호출 대상이 아니다.
- Claude Code는 `codex exec` subprocess, headless는 foreground serial subprocess 경로를 사용한다.
  현재 세션의 위임 권한과 실행 경계는 [AGENTS.override.md](../../../../AGENTS.override.md)를 따른다.
- Shared skill 노출 정책의 SoT는 [`default.nix`](../../../../modules/shared/programs/codex/default.nix)의
  `exposedCodexSkills`와 `intentionallyNotExposed`다.
  [`verify-ai-compat.sh`](../../../../scripts/ai/verify-ai-compat.sh)는 이 정책과 project directory projection을
  독립적으로 감사하는 oracle이다.
- Project projection은 `.agents/skills/<name>` directory symlink 단위다. repo-local target은
  `../../.claude/skills/<name>`이어야 하고 투영된 `SKILL.md`에 접근 가능해야 한다. 레거시 실디렉토리,
  누락·대상 불일치·고아 entry는 실패하며, 접근 가능한 `SKILL.md`를 가진 절대 target plugin symlink는 허용한다.
- 설치 버전과 실제 실행 경로는 `command codex --version` 및 `type -a codex`로 확인한다. 공식 native 설치본을 사용하며 문서의 확인 버전은 검증 시점 기록이다. 버전 스탬프는 `SKILL.md`의 "작성 기준"에만 두고, CLI 업데이트 후 해당 재검증 명령을 실행한다.

## 증상

1. Codex에서 `.agents/skills/<name>/SKILL.md` 기반 스킬이 일부/전부 누락됨
2. `verify-ai-compat.sh` 기준으로는 구조가 있어 보이는데 런타임 인식이 불안정함
3. 별개로, 권한 승인 프롬프트가 반복적으로 나타남 (정책 기본값 영향)

## 재현 조건

- `.agents/skills/*/SKILL.md`가 심링크일 때 환경에 따라 project-scope 스캔이 누락됨

## 원인 분석

1. SKILL.md 투영 방식 (근본 원인)
- 기존 투영은 `.claude/skills/<name>/SKILL.md`를 `.agents/skills/<name>/SKILL.md`로 심링크했다.
- 일부 Codex 환경에서 symlinked `SKILL.md`가 project-scope 발견 과정에서 누락될 수 있었다.

2. 검증 기준 불일치
- 기존 검증 스크립트가 "심링크여야 정상" 기준으로 작성되어 실제 호환 수정 이후 기준과 충돌했다.

3. 정책/발견 이슈 혼재
- 승인 프롬프트 문제(`approval_policy`, `sandbox_mode`)와 Skills 발견 문제를 한 원인으로 혼동하기 쉬웠다.
- 실제로 Skills 누락의 근본 원인은 `trust`가 아니라 `SKILL.md` 심링크였다.

## 해결 내용

### 1) SKILL.md 투영 정책 변경

- 파일: `modules/shared/programs/codex/default.nix`
- 변경: `.agents/skills/<name>/SKILL.md`를 심링크가 아니라 실파일 복사로 생성
- 유지: `references`, `scripts`, `assets`는 심링크 유지

> 2026-02-19 업데이트: 이후 디렉토리 심링크로 전환됨. 하단 "2026-02-19 재검증" 섹션 참조.

### 2) 검증 스크립트 기준 변경

- 파일: `scripts/ai/verify-ai-compat.sh`
- 변경:
  - `SKILL.md`가 일반 파일인지 확인
  - 심링크면 실패 처리
  - 원본과 `cmp`로 내용 일치 확인

### 3) 실행 정책 기본값 반영 (권한 프롬프트 대응)

- 파일: `modules/shared/programs/codex/files/config.toml`
- 반영 상태:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

### 4) trust 항목 정리

- 프로젝트별 절대경로 trust 항목은 환경 이식성(`$HOME`/OS 차이) 문제를 만들 수 있어 기본 구성에서 제거했다.
- 필요 시 호스트별/로컬 오버라이드로만 추가한다.

## 검증 절차

```bash
# 1) 구조 검증
./scripts/ai/verify-ai-compat.sh

# 2) SKILL.md 도구-중립성 lint fixture 검증
./scripts/ai/verify-ai-compat.sh --run-fixture-tests

# 3) directory symlink 검증
for d in .agents/skills/*; do
  name="$(basename "$d")"
  target="$(readlink "$d" 2>/dev/null || true)"
  expected="../../.claude/skills/$name"
  if [ -d ".claude/skills/$name" ]; then
    target_ok=false
    [ "$target" = "$expected" ] && target_ok=true
  else
    target_ok=false
    [[ "$target" = /* ]] && target_ok=true
  fi
  if [ -L "$d" ] && [ -d "$d" ] && [ -f "$d/SKILL.md" ] && $target_ok; then
    echo "OK: $name -> $target"
  else
    echo "FAIL: $name"
  fi
done

# 4) 공식 CLI의 설치 버전과 업데이트 인터페이스 확인
command codex --version
command codex --help
command codex update --help

# 5) 런타임 인식 검증
codex -a never exec "Answer YES or NO only: Is a skill named 'configuring-codex' available in this workspace?"
```

## 2026-02-08 확인 결과

- 심링크 수: `0`
- 일반 파일 수: `18` (2026-02-08 당시 기준)
- `./scripts/ai/verify-ai-compat.sh`: `검증 완전 통과`
- `codex exec` 런타임 질의:
  - `managing-secrets` 가용성: `YES`
  - project 스킬 목록이 응답에 포함됨
- 새 Git 프로젝트에서도 승인 선택지 미노출(`approval_policy = "never"`, `sandbox_mode = "danger-full-access"` 적용 후)

## codex trust 관련 메모

- `codex-cli 0.144.1` 기준 `codex --help`에 `codex trust` 독립 서브커맨드는 확인되지 않았다.
- 프로젝트 trust의 SoT는 사용자 승인에 의한 디렉토리별 runtime mutation이다. Nix template은 trust를
  하드코딩하지 않고 runtime-owned `config.toml`의 `[projects.*]` 엔트리를 보존한다.
- 본 케이스에서 Skills 누락의 근본 원인으로는 확인되지 않았다(심링크 이슈가 근본 원인).

## 회귀 방지 체크리스트

아래 전체 점검은 스킬 추가·제거·노출/설치 경로·정책 변경에 적용한다. 일반 문구나 reference 편집은 영향받는 문서·링크와 관련 검사만 실행한다. runtime 표면이 달라졌거나 구조 검사로 설명되지 않는 문제가 있을 때만 모델 호출 probe를 추가한다.

1. 노출·정책 변경 후 `nrs` 실행
2. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
3. `./scripts/ai/verify-ai-compat.sh` 통과 확인
4. 실제 스킬 선택/로드 문제가 남으면 해당 project-scope 스킬 1개로 런타임 확인 (호출 전 실행 계약 적용)
5. `configuring-codex` 스킬 문서와 실제 구현(`default.nix`, verify script) 간 불일치 여부 점검
6. pre-commit `ai-skills-consistency` 훅 확인 (관련 staged 변경 시 fail, 긴급 우회: `SKIP_AI_SKILL_CHECK=1`)
7. 첫 PATH 매치가 공식 native CLI인지 확인한다. mise shim·npm 글로벌·오래된 Nix 설치본이 앞서지 않아야 하며, `verify-ai-compat.sh`의 PATH 검사를 함께 확인한다.
8. `cleanupManualNodeCodex`가 수동 npm 글로벌 잔재를 정리하고 native CLI를 가리지 않는지 확인한다. Node의 mise 관리는 유지한다.
9. 공식 CLI의 `packages/standalone`과 원격 데몬의 `packages/app-server-daemon`을 구분한다. 일반 CLI 링크는 전자가 정상이며 후자를 가리키면 충돌이다.

## 2026-05-02 업데이트: SKILL.md 도구-중립성 lint

`verify-ai-compat.sh`는 `SKILL.md` 본문에 남은 특정 런타임 전용 도구 지시를 검사한다.
일반 실행에서 FAIL findings는 기존 `fail()` 경로로 집계되어 exit 1을 만든다. WARN findings는
보고만 하고 exit 0을 유지한다.

정책 요약:

- YAML frontmatter는 metadata로 보고 본문 lint에서 제외한다.
- fenced code block은 예시 코드로 보고 제외한다.
- blockquote 안의 FAIL literal은 WARN으로 downgrade한다.
- 런타임별 binding을 보여주는 구조적 mapping table은 예외로 허용하되, 일반 prose는 엄격하게 검사한다.
- `set-icons`, `using-claude-p`, `using-codex-exec`는 별도의 SKILL.md lint 제외 목록을 따른다.

fixture만 빠르게 확인하려면 다음을 실행한다:

```bash
./scripts/ai/verify-ai-compat.sh --run-fixture-tests
```

## 2026-02-19 재검증: 디렉토리 심링크 전환

### 배경

2026-02-08 런북에서 "SKILL.md 심링크 불가 → 실파일 복사" 정책을 수립했으나,
이는 파일 심링크에 대한 결론이었다. 커뮤니티 리서치와 소스코드 분석을 통해
Codex CLI가 디렉토리 심링크는 공식 지원함을 확인했다.

### 핵심 발견

| 항목 | 기존 (2026-02-08) | 변경 (2026-02-19) |
|------|-------------------|-------------------|
| SKILL.md 투영 | 실파일 복사 | 디렉토리 심링크 |
| references/scripts/assets | 개별 파일 심링크 | 디렉토리 심링크에 포함 |
| sync drift | 복사 시점 차이로 발생 가능 | 원천 제거 (단일 소스) |

### 근거

- Codex CLI 소스코드 (`codex-rs/core/src/skills/loader.rs`):
  디렉토리 심링크는 `follow_links(true)`로 순회, 파일 심링크는 `continue`로 무시
- PR #8801 (2026-01-07 merged): 디렉토리 심링크 지원 추가
- OpenAI 공식 답변 (Issue #9365): "We support symlinks to a skill directory, not the SKILL.md file itself"
- 로컬 검증: 전체 스킬 디렉토리 심링크 전환 후 `codex exec` 런타임 정상 인식 확인

### 최종 정책

- `.agents/skills/<name>` → `../../.claude/skills/<name>` 디렉토리 심링크
- `verify-ai-compat.sh`, `warn-skill-consistency.sh`에서 디렉토리 심링크 기준 검증

## 2026-11-12: 공식 native CLI와 원격 데몬 분리

과거 mise npm backend와 Nix overlay 설치를 공식 native 설치로 대체한다. 비대화형 PATH에서
mise shim이나 수동 npm 글로벌이 앞서는 문제를 막는 기존 잔재 정리는 유지한다.

### 설치와 설정의 소유 범위

- CLI 설치는 [OpenAI 공식 installer](https://chatgpt.com/codex/install.sh)가 소유한다.
  `default.nix`의 `installCodexCli`는 실행 가능한 CLI가 없을 때만 최초 설치하며, 반복 activation은
  설치 버전을 바꾸지 않는다. dry-run에는 다운로드·설치가 없고 설치 실패는 실패로 드러난다.
- CLI의 업데이트 안내에서 사용자가 적용 여부를 선택한다. 직접 업데이트를 원할 때
  `command codex update`를 사용한다. 지원 옵션은 `command codex update --help`, 현재 버전은
  `command codex --version`으로 확인한다. CLI 예약 업데이트는 구성하지 않는다.
- Nix는 설정 병합·훅·스킬·PATH·최초 설치 배선과 이전 설치 방식의 잔재 정리를 계속 관리한다.
  바이너리 전환 과정에서 설정·인증·대화 데이터를 지우지 않는다.
- Node와 패키지 매니저는 mise에 유지한다. Codex의 mise npm backend는 복원하지 않는다.
  `cleanupMiseCodexShim`과 `cleanupManualNodeCodex`는 native CLI를 가리는 이전 설치본을 정리한다.
  수동 `npm install -g @openai/codex`는 다시 같은 충돌을 만들므로 사용하지 않는다.

### 진단

일반 CLI 진입점 `~/.local/bin/codex`는 공식 native 설치본인
`~/.codex/packages/standalone/releases/<release>/bin/codex`를 가리키는 링크가 정상이다.
원격 데몬 전용 실행본은 `~/.codex/packages/app-server-daemon/current/bin/codex`다.
첫 PATH 매치와 링크 대상을 함께 확인하여 mise shim·npm 글로벌·오래된 Nix 설치본이나
데몬 전용 실행본이 일반 CLI를 대신하지 않게 한다. `standalone`이라는 이름 자체는 충돌 증거가 아니다.

```bash
type -a codex
command codex --version
command codex --help
command codex update --help
```

셸 wrapper를 우회해 버전·도움말을 읽을 때는 `command codex`를 쓴다.
설정·스킬 변경 뒤에는 `nrs`와 `./scripts/ai/verify-ai-compat.sh`로 적용 상태를 확인한다.
업데이트 성공과 설정 적용 성공은 따로 확인한다.

### 원격 데몬

원격 app-server는 `app-server-daemon` 아래의 전용 실행본을 사용한다. 설치된 native CLI에서
`from-cli` 방식으로 준비하며 `autoUpdateEnabled=false`를 유지한다. 관리 timer는 CLI 업데이트를
실행하지 않는다. 사용자가 CLI를 갱신한 뒤 설치된 버전을 기준으로 데몬 실행본과 상태를 확인한다.

- 일반 CLI의 `standalone`과 데몬 전용 `app-server-daemon`은 경로와 실행 수명을 분리한다.
  일반 CLI가 데몬 전용 경로를 가리키는 경우만 이 둘 사이의 PATH 충돌로 처리한다.
- timer는 `codex doctor`를 실행하지 않는다. 설치된 CLI와 데몬 실행본의 일치, 인증 상태,
  daemon/start 상태를 확인한다. 소유권 판정과 정지·교체는 공식 lifecycle에 맡긴다.
  원시 PID에 대한 주기적 종료·복구는 하지 않으며, 소유권이 불명확한 프로세스는 보고만 한다.
- Desktop SSH는 `CODEX_SSH_SKIP_APP_SERVER_BOOT=true`인 login shell에서 관리형 서버의
  proxy로만 연결한다. 별도 app-server 자동 기동은 관리 계약과 충돌한다. 연결 전후에 같은
  관리형 프로세스를 사용하는지 확인하며, 서버가 내려가 있으면 ensure를 먼저 복구한다.
- SSH proxy가 연결되어 있으면 버전 교체는 exit 62 / `version-update-deferred-ssh-connected`로
  보류한다. 이때 `remoteControlEnabled: null`은 미확인이지 disabled 판정이 아니다.
  `remote-control start`도 상태에 따라 재시작할 수 있어 보류 경로에서 호출하지 않는다.
- 연결 검사 후 새 proxy가 붙는 경합은 원자적으로 차단하지 못한다. 계획된 교체에서는 연결을
  해제한 상태를 유지한다. 연결 종료 후 다음 점검에서 교체한다.
- socket/daemon/PID lock 파일을 직접 삭제하지 않는다. 정지·교체와 필요한 소켓 정리는
  공식 lifecycle이 처리한다. 외부에서 lock을 unlink하면 살아 있는 flock inode를 우회할 수 있다.
- 같은 원인 코드의 지속 장애는 최초 통지 후 6시간마다 재알림한다. 원인이 바뀌면 기존
  30분 쿨다운을 적용하고, 복구와 복구 후 재발은 바로 알린다.

운영 확인:

```bash
systemctl status codex-remote-control-ensure.service codex-remote-control-ensure.timer
journalctl -u codex-remote-control-ensure.service -n 80 --no-pager
jq '{exitCode,lastAction,lastRepairReason,authMode,operatorCli,managedCodexVersion,appServerVersion,remoteControlEnabled}' /var/lib/codex-remote-control/status.json
```

제어 소켓 위치 (0.156.1 기준, 재확인: `readlink ~/.codex/app-server-control/app-server-control.sock`):
`~/.codex/app-server-control/app-server-control.sock`은 symlink이고 실체는 설정 불가한
`/tmp/codex-daemon-<uid>/<sha256>`이다. 그래서 ensure 서비스는 `PrivateTmp`를 쓰지 않는다 — 켜면 unit 종료 시
private /tmp와 함께 데몬 소켓이 지워진다 (eval Test CRC1이 고정).

관리 상태 조회가 실패하거나 실행 중 서버의 소유권이 확인되지 않으면 진단 결과만 보고한다.
프로세스 이름이나 실행 경로·버전 차이만으로 종료 대상을 결정하지 않는다. 원시 PID에 TERM을
보내거나 소켓·lock 파일을 지워 복구하는 절차는 사용하지 않는다.

원격 연결 복구 순서:

1. 설정을 적용한 뒤 새 SSH login shell에 `CODEX_SSH_SKIP_APP_SERVER_BOOT=true`가 전달되는지 확인한다.
2. 실행 중 작업과 SSH 연결 상태를 확인한다. 연결된 proxy가 있으면 교체를 보류한다.
3. 현재 CLI 도움말과 공식 lifecycle의 상태·소유권 판정에 따라 복구한다. 소유권을 확인하지 못하면
   중단하고 보고하며, 사용자 요청 없이 기존 프로세스를 종료하지 않는다.
4. 관리 상태와 실제 `remoteControl/status/read`의 `connected`를 확인한다.
5. SSH 재연결 뒤에도 관리형 서버가 유지되는지 확인한다. 조회 성공이나 버전 일치만으로
   lifecycle 소유권이 증명되었다고 보지 않는다.

## 참고 문서

- https://developers.openai.com/blog/eval-skills
- https://developers.openai.com/codex/skills
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-basic
- https://developers.openai.com/codex/config-advanced
- https://developers.openai.com/codex/config-reference
- https://developers.openai.com/codex/security/
- https://github.com/openai/codex/issues/4392
- https://github.com/openai/codex/pull/8801
- https://github.com/openai/codex/pull/9384
- https://github.com/openai/codex/issues/9365
