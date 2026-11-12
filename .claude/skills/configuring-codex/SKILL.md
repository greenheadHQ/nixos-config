---
name: configuring-codex
description: |
  Configure Codex CLI settings and troubleshoot AGENTS.md/.agents/skills symlink projection.
  Trigger: 'Codex 설정', 'codex 스킬 인식', 'AGENTS.md 심링크', '.agents/skills 심링크', 'verify-ai-compat',
  'codex 권한', 'codex 업데이트', 'AI 도구 호환', 'codex 바이너리', 'approval_policy', 'sandbox_mode',
  'Codex 권한 프롬프트'.
  NOT for codex exec 실행. Direct Codex는 native subagent를 우선하며, Claude/headless subprocess 계약은 아래 런타임 SoT를 참조.
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 작성 기준

- CLI 설치·업데이트는 OpenAI 공식 native installer와 CLI가 소유한다. Nix는 설정·훅·스킬과 최초 설치를 관리한다.
- 확인 날짜: 2026-11-12
- 확인 버전: codex-cli 0.167.2 (공식 installer의 임시 설치본에서 `--version`·`--help`·`update --help` 확인; 배포 상태와 구분)
- 재검증: `command codex --version && command codex --help && command codex update --help`

## 목적과 범위

- `~/.codex/config.toml` 실행 정책(`approval_policy`, `sandbox_mode`) 및 모델 설정
- `AGENTS.md`/`.agents/skills` 투영 구조
- `.agents/skills/*` 디렉토리 심링크 검증
- `nrs`(또는 동등 activation) 이후 결과 검증
- Claude Code / Codex CLI 등 AI 에이전트별 동작 차이 정리

## 빠른 진단 체크리스트

1. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
2. 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크 확인 (git-tracked)
3. `./scripts/ai/verify-ai-compat.sh` 실행
4. 문서화된 runtime recognition 검사로 `codex exec`에서 스킬 이름이 보이는지 확인
5. 권한 프롬프트 이슈는 `approval_policy`, `sandbox_mode` 설정으로 분리 진단

## 런타임 라우팅과 노출 경계

| 세션 | 기본 실행 경로 |
|------|----------------|
| Direct Codex | native subagent. `using-codex-exec`은 자기 참조 방지를 위해 의도적으로 노출하지 않으며 직접 호출 대상이 아니다. |
| Claude Code | `codex exec` subprocess. `using-codex-exec`은 이 경로를 위한 adapter 문서다. |
| headless | `codex exec` subprocess를 foreground serial로 실행한다. |

위임 권한과 실행 경계는 프로젝트의 [AGENTS.override.md](../../../AGENTS.override.md)를 따른다. 현재 세션이 제공하는 도구와 동시 실행 상한을 확인한다.

Shared skill 노출 정책의 SoT는
[`default.nix`](../../../modules/shared/programs/codex/default.nix)의 `exposedCodexSkills`와
`intentionallyNotExposed`다. [`verify-ai-compat.sh`](../../../scripts/ai/verify-ai-compat.sh)는
그 목록과 project directory projection을 독립적으로 감사하는 oracle이다.

## `request_user_input` Default Mode 활성화

codex 0.106+에서 default (code) collaboration mode에서도 `request_user_input` 도구 사용 가능 (openai/codex#10384, PR openai/codex#12735). 본 nixos-config는 자기 환경 한정으로 활성화 가정.

활성화 절차:
1. `modules/shared/programs/codex/files/config.toml` 및 `config.darwin.toml`의 `[features]` 섹션에 `default_mode_request_user_input = true` 확인 (commit b94fd06에서 추가됨).
2. `codex --version`이 0.106+ 인지 확인.
3. `nrs` 후 `~/.codex/config.toml`에 flag가 반영되었는지 확인.

검증:
- codex 세션 default mode에서 `use request_user_input to ask me ...`로 invoke 시 tool call이 실제 발생하는지 (plain-text 응답이 아닌지) 관찰.
- 0.106 release 댓글에 따르면 default mode 모델은 "make assumptions and only stop if blocked" 정책으로 자동 호출하지 않으므로, 인터뷰 기반 스킬 본문에 명시적 사용 지시가 있어야 한다.
- 옵션 개수/Recommended 라벨은 schema/server enforcement가 아니라 codex tool description의 LLM convention이다 (codex 0.128 main fact-check 기준 — `tools/src/request_user_input_tool.rs`의 JSON Schema description 문자열에 "2-3 choices", "recommended option first" 가이드 존재). PR openai/codex#12735는 mode 가용성만 확장하고 schema는 미변경. prompt template 차원에서는 mode별 차이 있음 (`plan.md`만 "2-4 options + recommended default" 명시).

## 핵심 파일

- `modules/shared/programs/codex/default.nix` — 설정, shared skill 노출 정책 SoT, project 스킬 투영 activation 배선
- `modules/shared/programs/codex/files/project-codex-skills.sh` — project 스킬 투영과 고아 링크 정리 본체
- `modules/shared/programs/codex/files/config.toml` — 실행 정책/모델 설정 (NixOS)
- `modules/shared/programs/codex/files/config.darwin.toml` — macOS 전용 설정 (user-scope MCP 포함)
- `modules/shared/programs/codex/files/retired-config-keys.txt` — 배포본에서 회수할 퇴역 키 목록 SoT (activation·nrs 복구·verify가 공유)
- `scripts/ai/verify-ai-compat.sh` — 노출 정책 및 directory projection 독립 감사 oracle
- `modules/shared/programs/claude/files/CLAUDE.md` — 글로벌 라우팅/지침
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## 설치/업데이트 경로

Codex CLI는 [OpenAI 공식 native installer](https://chatgpt.com/codex/install.sh)로 설치한다.
`modules/shared/programs/codex/default.nix`의 `installCodexCli` activation은 실행 가능한 CLI가
없을 때만 최초 설치한다. 이미 설치된 release는 반복 `nrs`로 갱신하지 않는다. 초기 설치 실패는
activation 실패로 드러나며, dry-run은 다운로드·설치를 수행하지 않는다.

CLI가 업데이트를 안내하면 사용자가 적용 여부를 선택한다. 직접 업데이트를 원할 때는
`command codex update`를 사용하며 옵션은 `command codex update --help`로 확인한다.
CLI를 예약 갱신하는 timer나 activation 절차는 없다.
설치 버전은 `command codex --version`으로 확인하며 저장소 변경이나 재빌드로 버전을 맞추지 않는다.

Nix의 관리 범위는 유지한다: `config.toml` 병합, 퇴역 설정 키 제거, 훅·스킬 투영, PATH와
이전 설치 방식의 잔재 정리. `cleanupMiseCodexShim`과 `cleanupManualNodeCodex`는 mise shim과
수동 npm 글로벌이 native CLI를 가리지 않도록 유지한다. Node와 패키지 매니저는 계속 mise가 관리한다.
`npm install -g @openai/codex`를 새 설치 경로로 쓰지 않는다.

일반 CLI의 진입점 `~/.local/bin/codex`는 공식 native 설치본인
`~/.codex/packages/standalone/releases/<release>/bin/codex`를 가리키는 링크가 정상이다.
첫 PATH 매치와 링크 대상을 함께 확인해 mise shim·npm 글로벌·오래된 Nix 설치본이 앞서지 않게 한다.
원격 데몬 전용 실행본은 `~/.codex/packages/app-server-daemon/current/bin/codex`로 분리한다.
일반 CLI가 이 데몬 전용 경로를 가리키는 경우가 충돌이다. 설정·인증·대화 데이터는 보존한다.

```bash
command codex --version
command codex --help
command codex update --help
type -a codex
```

### 원격 데몬과 업데이트 경계

원격 데몬은 `app-server-daemon` 아래의 전용 실행본을 사용한다. 설치된 native CLI에서
`from-cli` 방식으로 준비하고 `autoUpdateEnabled=false`를 유지한다. 주기 점검은
CLI 최신 버전을 내려받지 않으며, 사용자가 갱신한 CLI에 맞춰 데몬 상태를 확인한다.

SSH proxy가 연결되어 있으면 버전 교체와 재시작을 보류한다. 연결 유무를 검사한 뒤 새 연결이
들어오는 경합까지 원자적으로 막지는 못한다. 계획된 교체에서는 연결을 해제한 상태를 유지한다.
이 보류 경로에서는 `remote-control start`처럼 재시작을 유발할 수 있는 동작도 실행하지 않는다.
프로세스 소유권 판정과 정지·교체는 공식 lifecycle에 맡긴다. 주기 점검에서 원시 PID를
종료하지 않으며, 소유권을 확인하지 못한 프로세스는 보고만 한다. 데몬 소켓·PID lock 파일도 직접 삭제하지 않는다.
상세 복구는 [운영 문서](references/runbook-codex-compat.md)의 원격 데몬 절차를 따른다.

설정·스킬 노출을 변경한 뒤에는 `nrs`에 이어 `./scripts/ai/verify-ai-compat.sh`로 적용 상태를 확인한다.
CLI 업데이트는 이 설정 변경 절차와 별개다.

## 진단 우선순위 (중요)

Skills 누락 이슈의 1차 원인은 `trust`보다 투영 방식이다.
Codex CLI는 디렉토리 심링크를 따라가지만 파일 심링크는 무시한다 (PR #8801).
`.agents/skills/<name>`은 반드시 디렉토리 심링크여야 하며, SKILL.md 파일 자체를 심링크하면 안 된다.

## 실행 정책 / Trust 메모

`codex-cli 0.153.4` 기준으로 `codex --help`에 `codex trust` 독립 서브커맨드는 확인되지 않았다
(재검증: `command codex --help | grep -cE '^\s+trust'` → 0).
권한 프롬프트 동작은 전역 실행 정책으로 제어한다.

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

프로젝트 trust의 SoT는 사용자 승인에 의한 디렉토리별 runtime mutation이다. Nix template은
trust를 하드코딩하지 않고 runtime-owned `config.toml`의 `[projects.*]` 엔트리를 보존한다.

### 선언 소유 vs 앱 소유 (config.toml)

`~/.codex/config.toml`은 nix 템플릿과 Codex 앱이 함께 쓰는 파일이다. sync는 템플릿이 선언한 leaf만
덮어쓰고(template-owned) 나머지는 보존한다(user-owned). 앱 UI가 쓰는 키를 템플릿에 두면 nrs마다
되돌아가 UI 선택이 무효가 되므로, 경계는 다음과 같이 둔다 (2026-09-05 결정,
2026-10-16 사용자 요청으로 메모리 처리 모델 두 키만 선언 소유로 추가).

| 소유 | 키 | 근거 |
|------|----|------|
| 템플릿(선언) | `approval_policy`, `sandbox_mode`, `[features]`, `[agents]`, `[[hooks.*]]`, `[notice]` | 정책·안전 경계. 사용자가 UI로 바꾸는 값이 아니다 |
| 템플릿(메모리 모델) | `memories.extract_model`, `memories.consolidation_model` | 사용자 요청으로 추출은 `gpt-6-luna`, 통합은 `gpt-6.1-terra`로 고정. 나머지 메모리 설정은 보존 |
| 앱(UI persist) | `model`, `model_reasoning_effort`, `service_tier` | Desktop/TUI 선택이 최상위 키로 기록됨. 템플릿에서 제거 |
| 앱(런타임 상태) | `[projects.*]`, `tui`, `desktop`, `memories`의 위 두 모델 외 설정, `plugins`, `skills`, `marketplaces`, `notify`, `mcp_servers` | 앱이 생성·갱신. 템플릿은 선언하지 않는다 |

`gpt-6.1-terra`는 Codex CLI 0.159.0 이상이 필요하다 ([공식 모델 문서](https://learn.chatgpt.com/docs/models)). 설치 버전은 위 재검증 명령으로 확인한다.

템플릿에서 키를 지워도 배포본에는 user-owned로 남는다. 배포본에서까지 영구 회수해야 하는 정책 키는
[`retired-config-keys.txt`](../../../modules/shared/programs/codex/files/retired-config-keys.txt)에
등록한다 — 그러면 `nrs`가 activation과 NO_CHANGES 복구 양쪽에서 제거하고, `verify-ai-compat.sh`가
잔존을 `retired_key_present` drift로 잡는다. 등록한 키를 템플릿이 다시 선언하면 스크립트가
EXIT_ERROR로 막는다(선언과 회수가 겹치면 sync가 매번 썼다 지우고 check가 영원히 drift를 내
수렴하지 않으므로). 목록은 두 플랫폼 템플릿 공용이라 양쪽 모두 선언하지 않는 키만 넣는다.

앱 소유 키(`model`, `model_reasoning_effort`, `service_tier`)는 이 목록에 넣지 않는다 — 영구 회수는
매 `nrs`마다 사용자의 UI 선택까지 지운다. 이 키들의 옛 템플릿 pin 잔재는 "1회만 지우고 그 뒤로는
보존"이라 회수 메커니즘으로 표현할 수 없으므로 호스트별 1회 수동 삭제로 처리한다(절차는 config
템플릿 헤더 주석).

## 트러블슈팅 / FAQ

- 스킬이 안 보임: `.agents/skills/*`가 파일 심링크인지 확인하고 디렉토리 심링크로 교정한다.
  `nrs` 출력에 `Warning: keeping .agents/skills/<name>`이 있으면 그 자리의 실디렉토리·파일이 투영을
  막고 있다 — 처리 규칙은 아래 "투영 아키텍처"를 따른다. MiniPC(NixOS)에서는 activation이
  `home-manager-<primaryUser>` 서비스로 돌아 이 경고가 `nrs` 출력이 아니라 journal로 가므로,
  `journalctl -u home-manager-<primaryUser>`에서 확인하거나 메인 체크아웃의 `verify-ai-compat.sh`로 확인한다.
- 권한 프롬프트 반복: `~/.codex/config.toml`의 `approval_policy`, `sandbox_mode`를 확인한다.
- AGENTS 불일치: `AGENTS.md` 자리가 일반 파일이나 실디렉토리면 `nrs`가 보존하고
  `Warning: keeping AGENTS.md`를 stderr로 남긴다. 내용을 확인해 필요한 수정은 `CLAUDE.md`에
  반영하고 해당 파일·디렉토리를 옮기거나 지운 뒤 `nrs`로 심링크를 복구한다. 검증기도 보존된
  자료와 링크 누락을 구분해 안내한다. 정상 링크·다른 대상의 링크·링크 부재는 자동으로 수렴한다.
- 활성화 누락: `nrs` 실행 후 `./scripts/ai/verify-ai-compat.sh`로 재검증한다.
- CLI 업데이트가 안 됨: `command codex update --help`와 `type -a codex`로 업데이트 인터페이스와 첫 실행 대상을 확인한다. 일반 CLI는 공식 native 설치본이어야 한다. 반복 `nrs`나 npm 재설치로 버전을 갱신하지 않는다.

## 투영 아키텍처

```
.claude/skills/<name>/                  # 단일 원본 (SKILL.md, references/ 등)
      -> directory symlink
.agents/skills/<name>/                  # ../../.claude/skills/<name> 심링크
```

Codex CLI는 디렉토리 심링크를 `follow_links(true)`로 순회한다 (PR #8801).
파일 심링크는 무시되므로 반드시 디렉토리 단위로 심링크해야 한다.

투영은 원본마다 `.agents/skills/<name>` 자리를 본다. 올바른 관리 링크면 그대로 두고, 없으면 만들고,
다른 대상을 가리키는 심링크면 링크만 관리 링크로 바꾼다(링크 대상은 건드리지 않는다). 그 자리의
실디렉토리와 파일은 git 추적 여부와 관계없이 지우지 않는다.

- `SKILL.md`가 git 추적인 실디렉토리: `Skipping ... (run 'git pull' first)`를 출력한다. 심링크 전환
  커밋을 받기 전에 `nrs`가 먼저 돈 경우이므로 `git pull` 뒤 `nrs`를 다시 실행한다.
- 그 밖의 실디렉토리(전부 미추적, `SKILL.md`만 미추적, `SKILL.md` 없음)와 파일: 원인과 조치
  (`review its contents, move or delete it, then rerun nrs`)를 담은 `Warning: keeping .agents/skills/<name>`
  경고를 stderr로 남기고 rc는 0이다. 사용자 자료일 수 있으므로 내용을 확인해 옮기거나 지운 뒤 `nrs`를
  다시 실행한다. 정리 전까지 그 스킬은 Codex에 투영되지 않고 `verify-ai-compat.sh`가 실패로 보고한다.
- 추적 판정 명령 자체가 실패한 실디렉토리: 미추적으로 보지 않고 보존한다. 경고의 원인은
  `cannot tell whether it is git-tracked (git ls-files exit <rc>)`이고 조치는 위와 같다.

고아 정리는 activation이 만든 관리 링크(`../../.claude/skills/<name>` 상대 심링크) 중
원본이 사라진 것만 지운다. 원본 없는 실디렉토리와 다른 대상을 가리키는 링크는 지우지 않고
`Warning: keeping .agents/skills/<name>` 경고만 남긴다 — `verify-ai-compat.sh`가 이를 계속
고아 투영으로 보고하므로, 옮기거나 지우는 판단은 사람이 한다. 절대경로 target이면서
`SKILL.md`에 접근 가능한 플러그인 스킬 링크는 검증기와 같은 기준으로 경고 없이 보존한다.

## 활성화

원칙은 `nrs` 실행이다.  
환경 제약으로 `nrs`를 실행하지 못하면, Codex 모듈 activation과 동등한 절차로 재생성해도 된다.
그 절차는 저장소 루트에서 `DRY_RUN_CMD='' bash modules/shared/programs/codex/files/project-codex-skills.sh "$PWD"`다.
`DRY_RUN_CMD=echo`면 변경 명령만 출력하고, `DRY_RUN_CMD`를 생략하거나 git을 찾지 못하면 아무것도 바꾸지 않고 실패한다.

## 검증 명령

```bash
# 구조 검증
./scripts/ai/verify-ai-compat.sh

# 디렉토리 심링크 검증 (모두 심링크여야 함)
for d in .agents/skills/*; do
  [ -L "$d" ] && echo "OK: $(basename $d) -> $(readlink $d)" || echo "FAIL: $(basename $d)"
done

# 런타임 인식 검증
codex -a never exec "Answer YES or NO only: Is a skill named 'configuring-codex' available in this workspace?"
```

## 관련 계약

- Direct Codex 위임 권한과 실행 경계: [AGENTS.override.md](../../../AGENTS.override.md)

## 레퍼런스

- 상세 장애 기록 및 회귀 체크: `references/runbook-codex-compat.md`

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
