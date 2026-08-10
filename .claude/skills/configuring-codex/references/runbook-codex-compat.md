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
  세션별 binding의 정본은 [runtime mapping](../../../../modules/shared/programs/claude/files/skills/run-da/references/runtime-mapping.md),
  Direct Codex delegation fallback의 권한 계약은 [hardening contract](../../../../modules/shared/programs/claude/files/skills/run-da/references/hardening-contract.md)다.
- Shared skill 노출 정책의 SoT는 [`default.nix`](../../../../modules/shared/programs/codex/default.nix)의
  `exposedCodexSkills`와 `intentionallyNotExposed`다.
  [`verify-ai-compat.sh`](../../../../scripts/ai/verify-ai-compat.sh)는 이 정책과 project directory projection을
  독립적으로 감사하는 oracle이다.
- Project projection은 `.agents/skills/<name>` directory symlink 단위다. repo-local target은
  `../../.claude/skills/<name>`이어야 하고 투영된 `SKILL.md`에 접근 가능해야 한다. 레거시 실디렉토리,
  누락·대상 불일치·고아 entry는 실패하며, 접근 가능한 `SKILL.md`를 가진 절대 target plugin symlink는 허용한다.
- 실측 codex 런타임과 `codex-pin.json`의 버전 일치 확인: `jq -r .version modules/shared/programs/codex/codex-pin.json && codex --version` (확인 버전 스탬프는 `SKILL.md` "작성 기준"에만 기재한다 — 여기 박으면 bump 때 stale해진다. 버전 값 자체의 SoT는 `codex-pin.json`).

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

# 4) pin/runtime 버전 일치 검증
runtime_version="$(codex --version | awk 'NF { print $NF; exit }')"
pin_version="$(jq -r .version modules/shared/programs/codex/codex-pin.json)"
if [ -z "$runtime_version" ] || [ -z "$pin_version" ] || [ "$pin_version" = null ] ||
   [ "$runtime_version" != "$pin_version" ]; then
  echo "FAIL: runtime=$runtime_version pin=$pin_version" >&2
  exit 1
fi
echo "OK: runtime=$runtime_version pin=$pin_version"

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

1. 새 스킬 추가/수정 후 `nrs`(또는 동등 activation) 실행
2. `.agents/skills/*`이 디렉토리 심링크인지 확인 (`ls -la .agents/skills/`)
3. `./scripts/ai/verify-ai-compat.sh` 통과 확인
4. `codex exec`로 project-scope 스킬 1개 이상 런타임 확인
5. `configuring-codex` 스킬 문서와 실제 구현(`default.nix`, verify script) 간 불일치 여부 점검
6. pre-commit `ai-skills-consistency` 훅 확인 (관련 staged 변경 시 fail, 긴급 우회: `SKIP_AI_SKILL_CHECK=1`)
7. `command -v codex`가 nix profile/store 경로로 resolve되는지 확인 — mise shims 경로면 잔존 shim이 codex(nix profile)를 shadow하는 회귀(#890)이며, `verify-ai-compat.sh`의 codex PATH resolve 가드가 자동 검사한다
8. `cleanupManualNodeCodex`가 수동 `npm install -g @openai/codex` 잔재를 제거하는지 확인 — node가 mise에 남으므로 수동 글로벌이 PATH상 codex(nix profile)를 가리는 회귀의 근원
9. NixOS MiniPC remote-control standalone은 `~/.codex/packages/standalone/current/` 아래 app-server payload로만 허용한다. `~/.local/bin/codex`가 이 standalone을 가리키면 일반 Codex CLI를 shadow하는 회귀다.

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

## 2026-06-06 업데이트: codex 바이너리 nix overlay 이관 (#890)

> 2026-06-05의 "mise npm backend 운영" 절을 대체한다. mise shim 활성화가 비대화형 PATH에서
> fragile해 PATH 회귀(#815/#821/#823/#845/#858)와 fork 폭주(os error 35)가 반복되어, codex를
> mise에서 떼고 declarative nix overlay로 이관했다. node per-project 전환은 mise에 유지(부분 폐기).

### 설치 + 정리 activation

- 설치: nix overlay(`modules/shared/programs/codex/package.nix`, `libraries/packages.nix`의 `shared`
  경유) — macOS+NixOS 공통 nix profile/store. OpenAI 공식 GitHub 릴리스 prebuilt를 직접 핀한다
  (`codex-pin.json`). nixpkgs lag·제3자 flake 없이 최신 추적이 목적이며, codex-rs는 정적 바이너리
  2종(codex + codex-code-mode-host 사이드카 — 0.147.0+ 도구 실행 필수, 같은 bin/ 설치)이라
  fetch+install만 한다(컴파일·patchelf 없음). 최신화는 `update-codex` 한 줄.
- 정리 activation 3종(`default.nix`) — codex를 설치하지 않고, 과거 설치 방식 잔재가 PATH에서
  codex(nix profile)를 shadow하지 못하게 정리만 한다:
  1. `cleanupLegacyCodexCli` — 과거 GitHub ELF(NixOS)/brew cask(macOS) 잔재 정리
  2. `cleanupMiseCodexShim` — mise npm backend 잔재(`shims/codex`·`installs/npm-openai-codex/`) 멱등 제거.
     mise 명령을 호출하지 않고 순수 rm (dangling shim의 mise resolve가 fork 폭주원). config.toml의 codex
     entry는 mise 전역 config가 nix 선언(`modules/shared/programs/mise/config.toml`)으로 이관되며 선언에서
     제외되는 방식으로 소멸한다.
  3. `cleanupManualNodeCodex` — 수동 `npm install -g @openai/codex` 잔재 제거 (node가 mise에 남아 유효)

### SoT와 업데이트

- 버전 SoT: `modules/shared/programs/codex/codex-pin.json` (version/tag + flake systems 2개
  (aarch64-darwin·x86_64-linux)의 asset/hash와 codeModeHost.asset/hash; x86_64-linux는
  standalonePackage 추가). 업데이트는 `update-codex`(최신 stable 조회 →
  해시 prefetch → 핀 갱신 → nrs; `--pre`로 alpha 포함). platforms/asset 키는 정적 설정이라 손으로 관리.
- overlay는 OpenAI 릴리스를 직핀하므로 lag이 사실상 없다(직핀 최신). config 템플릿 feature floor
  (현재 0.124+)는 항상 충족. 갱신 후 `codex-pin.json` 변경을 커밋한다.
- `~/.config/mise/config.toml`은 nix 선언 read-only symlink다 (SoT:
  `modules/shared/programs/mise/config.toml`; 직접 편집·`mise use -g` 불가). codex entry는
  선언에 없으므로 배포 시 자동 소멸하고, `node`/`gitleaks`는 선언에 포함되어 보존된다.

### 운영 주의 (nix overlay)

- fetch 실패가 nrs를 막는다: codex는 `home.packages` 빌드 입력이라, fresh 빌드(post-GC 또는 핀 bump)에서
  GitHub 릴리스 fetch가 실패하면 `nrs`가 실패한다(과거 mise activation은 non-fatal이었음). `fetchurl`은
  hash로 캐시되므로 정상 시 재fetch는 없다.
- update-codex는 항상 메인 repo 대상: `@flakePath@`가 메인 체크아웃으로 고정되어, worktree에서
  `update-codex`를 실행해도 메인 repo의 `codex-pin.json`을 갱신·빌드한다(`nfu`와 동일 패턴).

### `npm install -g @openai/codex` 금지

node가 mise에 남으므로 수동 글로벌이 `~/.local/share/mise/installs/node/<ver>/bin`에 깔리면
PATH상 nix profile보다 앞서 codex를 가린다. `cleanupManualNodeCodex`가 각 node 버전
prefix의 npm으로 `env PATH="$node_prefix/bin:${pkgs.mise}/bin:$PATH" "$npm_bin" uninstall -g @openai/codex`를
반복 호출해 제거하므로, codex가 사라지거나 꼬인 것처럼 보인다.
`lts`/`24`/`latest` 같은 symlink 별칭 디렉토리는 `[ ! -L ]` 가드로 제외해 중복 uninstall을 막는다.

### 진단

```bash
whence -p codex   # PATH 첫 매치 (nix profile/store여야 정상; mise shims면 잔존 shim 회귀, node/<ver>/bin이면 수동 글로벌 잔재)
type -a codex     # 모든 후보
readlink -f ~/.codex/packages/standalone/current/bin/codex  # Codex App remote-control standalone payload
```

`codex`는 셸 alias로 래핑되어 있다 — Linux는 안내 `echo`를 `>&2`로 먼저 출력한 뒤
`command codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen`를 실행하고, macOS는 선행 echo 없이
같은 `command codex …`를 실행한다. 따라서 바이너리 자체 경로는 `whence -p codex`로 확인한다.

### 2026-06-29 업데이트: remote-control standalone 예외

ChatGPT mobile Codex sync를 위한 app-server는 일반 CLI와 별도의 standalone package layout을 사용한다.
이 payload는 `modules/shared/programs/codex/codex-pin.json`의 pinned `standalonePackage` asset/hash에서
동기화하며, systemd `codex-remote-control-ensure.service`가
`~/.codex/packages/standalone/releases/<version>-x86_64-unknown-linux-musl/`와 `current` symlink를 관리한다.

경계:
- 일반 `command -v codex`는 계속 Nix-managed profile/store 경로여야 한다.
- `~/.local/bin/codex`가 standalone을 가리키는 symlink이면 PATH shadow 회귀이므로 제거 대상이다.
- `update-codex`는 CLI asset hash·code-mode host hash와 standalone package hash를 함께 갱신한다.
- timer는 `codex doctor`를 실행하지 않는다. 대신 `ensure-running`이 pinned standalone 동기화,
  ChatGPT auth 확인, daemon/start 상태 확인, 버전 drift 재시작, stale socket 정리, 그리고 같은 사용자 +
  legacy app-server per-process 증거가 있는 경우에만 stale PID repair를 수행한다.

운영 확인:

```bash
systemctl status codex-remote-control-ensure.service codex-remote-control-ensure.timer
journalctl -u codex-remote-control-ensure.service -n 80 --no-pager
jq '{exitCode,lastAction,lastRepairReason,authMode,normalCodexResolved,managedCodexVersion,appServerVersion,remoteControlEnabled}' /var/lib/codex-remote-control/status.json
```

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
