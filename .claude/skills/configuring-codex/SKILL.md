---
name: configuring-codex
description: |
  Configure Codex CLI settings and troubleshoot AGENTS.md/.agents/skills symlink projection.
  Trigger: 'Codex 설정', 'codex 스킬 인식', 'AGENTS.md 심링크', '.agents/skills 심링크', 'verify-ai-compat',
  'codex 권한', 'codex 업데이트', 'AI 도구 호환', 'codex 바이너리', 'approval_policy', 'sandbox_mode',
  'Codex 권한 프롬프트'.
  NOT for harness 동기화 (use syncing-codex-harness). NOT for codex exec 실행 (use using-codex-exec).
---

# Codex CLI 설정

Codex CLI 호환 레이어와 프로젝트 스킬 발견 문제를 다룹니다.

## 작성 기준

- 확인 날짜: 2026-06-06
- 확인 버전: codex 0.137.0 (nix overlay — OpenAI 공식 릴리스 직핀; #890에서 mise npm backend → nix 이관)
- 재검증: `codex --version && ./scripts/ai/verify-ai-compat.sh`

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
4. `codex exec`로 런타임에서 스킬 이름이 보이는지 확인
5. 권한 프롬프트 이슈는 `approval_policy`, `sandbox_mode` 설정으로 분리 진단

## `request_user_input` Default Mode 활성화

codex 0.106+에서 default (code) collaboration mode에서도 `request_user_input` 도구 사용 가능 (openai/codex#10384, PR openai/codex#12735). 본 nixos-config는 자기 환경 한정으로 활성화 가정.

활성화 절차:
1. `modules/shared/programs/codex/files/config.toml` 및 `config.darwin.toml`의 `[features]` 섹션에 `default_mode_request_user_input = true` 확인 (commit b94fd06에서 추가됨).
2. `codex --version`이 0.106+ 인지 확인.
3. `nrs` 후 `~/.codex/config.toml`에 flag가 반영되었는지 확인.

검증:
- codex 세션 default mode에서 `use request_user_input to ask me ...`로 invoke 시 tool call이 실제 발생하는지 (plain-text 응답이 아닌지) 관찰.
- 0.106 release 댓글에 따르면 default mode 모델은 "make assumptions and only stop if blocked" 정책으로 자동 호출하지 않으므로, 인터뷰 기반 스킬 (`run-da`, `grill-me`) 본문에 명시적 사용 지시가 있어야 한다.
- 옵션 개수/Recommended 라벨은 schema/server enforcement가 아니라 codex tool description의 LLM convention이다 (codex 0.128 main fact-check 기준 — `tools/src/request_user_input_tool.rs`의 JSON Schema description 문자열에 "2-3 choices", "recommended option first" 가이드 존재). PR openai/codex#12735는 mode 가용성만 확장하고 schema는 미변경. prompt template 차원에서는 mode별 차이 있음 (`plan.md`만 "2-4 options + recommended default" 명시).

## 핵심 파일

- `modules/shared/programs/codex/default.nix` — 설정 및 스킬 투영
- `modules/shared/programs/codex/files/config.toml` — 실행 정책/모델 설정 (NixOS)
- `modules/shared/programs/codex/files/config.darwin.toml` — macOS 전용 설정 (user-scope MCP 포함)
- `scripts/ai/verify-ai-compat.sh` — 구조 검증
- `modules/shared/programs/claude/files/CLAUDE.md` — 글로벌 라우팅/지침
- `.claude/skills/*` (원본)
- `.agents/skills/*` (Codex 발견용 투영)

## 설치/업데이트 경로

Codex CLI 바이너리는 declarative nix overlay로 설치한다 (`modules/shared/programs/codex/package.nix`,
`libraries/packages.nix`의 `shared` 경유; macOS+NixOS 공통; #890에서 mise npm backend → nix 이관).
overlay는 OpenAI 공식 GitHub 릴리스의 prebuilt 바이너리를 직접 핀한다 — nixpkgs lag(수 주)이나
제3자 flake 신뢰 없이 최신 codex를 추적하기 위함이다. codex-rs는 정적 단일 바이너리(linux=musl,
darwin=signed macho)라 소스 컴파일·patchelf 없이 fetch + install만 하므로 nix profile/store 경로로
안정적으로 resolve된다(mise shim의 비대화형 PATH fragility 회피가 이관 동기 — #815/#821/#823/#845/#858).

- 버전 SoT: `modules/shared/programs/codex/codex-pin.json` (version/tag + flake systems 2개
  (aarch64-darwin·x86_64-linux)의 asset/hash). version/tag/hash는 `update-codex`로 bump하고,
  platforms/asset 키는 정적 설정이라 손으로 관리한다.
- 설치/정리 코드 SoT: `default.nix`의 정리 activation 3종(`cleanupLegacyCodexCli`,
  `cleanupMiseCodexShim`, `cleanupManualNodeCodex`). 이들은 codex를 설치하지 않고, 과거 설치 방식
  (GitHub ELF/brew cask, mise npm backend shim, 수동 npm 글로벌) 잔재가 PATH에서 codex(nix profile)를
  shadow하지 못하게 정리만 한다.

업데이트(한 줄로 최신 stable):

```bash
update-codex             # 최신 stable로 codex-pin.json bump + nrs
update-codex --pre       # alpha/prerelease 포함 최신
update-codex --no-build  # 핀만 갱신(nrs 생략)
```

`update-codex`는 OpenAI 릴리스에서 최신 `rust-vX.Y.Z`를 찾아 핀된 플랫폼 해시를 prefetch해
`codex-pin.json`을 갱신하고 `nrs`로 적용한다(mise 미호출). 갱신 후 `codex-pin.json` 변경을 커밋한다.
nix는 lock 기반이라 "자동 최신"은 없고 — `update-codex` 한 줄이 그 역할을 한다.

### 왜 nixpkgs가 아니라 직접 overlay인가

nixpkgs codex는 cache.nixos.org prebuilt가 있어 편하지만 upstream 대비 수 주 lag이 있고, codex는
릴리스가 매우 잦아 lag이 실사용에 거슬린다. 그래서 OpenAI 공식 릴리스를 직접 핀해 lag 0 + 제3자
flake 신뢰 0 + 컴파일 0(prebuilt fetch)으로 간다. 대안(nixpkgs lag / 커뮤니티 flake `codex-cli-nix`의
단일 메인테이너 신뢰)은 트레이드오프가 있어 채택하지 않았다. config가 요구하는 feature floor(현재
0.124+ stable hooks, #585/#584)는 항상 직핀 최신이 충족한다.

`npm install -g @openai/codex` 금지:
node는 mise에 남으므로(codex만 부분 폐기, #890) 수동 글로벌이 `~/.local/share/mise/installs/node/<ver>/bin`에
깔리면 PATH상 nix profile보다 앞서 codex를 가린다. 다음 `nrs`의 `cleanupManualNodeCodex`가
각 node 버전 prefix의 npm으로 `env PATH="$node_prefix/bin:${pkgs.mise}/bin:$PATH" "$npm_bin" uninstall -g @openai/codex`를
반복 호출해 수동 글로벌을 제거하므로, codex가 사라지거나 꼬인 것처럼 보인다.
(`lts`/`24`/`latest` 같은 symlink 별칭 디렉토리는 `[ ! -L ]` 가드로 제외해 중복 uninstall을 막는다.)

진단 — codex shadow가 의심되면 PATH 첫 매치를 확인한다:

```bash
whence -p codex   # PATH 첫 매치 (nix profile/store여야 정상; mise shims 경로면 잔존 shim 회귀)
type -a codex     # 모든 후보 (node/<ver>/bin이 앞이면 수동 글로벌 잔재)
```

검증: `codex --version`, `./scripts/ai/verify-ai-compat.sh`(codex PATH resolve 가드 포함).
잔존 mise codex shim이 PATH 앞에서 codex(nix profile)를 가리는 회귀는 `managing-mise`의 셸 활성화 구조를 참조한다.

## 진단 우선순위 (중요)

Skills 누락 이슈의 1차 원인은 `trust`보다 투영 방식이다.
Codex CLI는 디렉토리 심링크를 따라가지만 파일 심링크는 무시한다 (PR #8801).
`.agents/skills/<name>`은 반드시 디렉토리 심링크여야 하며, SKILL.md 파일 자체를 심링크하면 안 된다.

## 실행 정책 / Trust 메모

`codex-cli 0.137.0` 기준으로 `codex trust` 독립 서브커맨드는 확인되지 않았다.  
권한 프롬프트 동작은 전역 실행 정책으로 제어한다.

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

`trust_level` 프로젝트 엔트리는 경로별 세부 제어가 필요할 때만 추가한다.

## 트러블슈팅 / FAQ

- 스킬이 안 보임: `.agents/skills/*`가 파일 심링크인지 확인하고 디렉토리 심링크로 교정한다.
- 권한 프롬프트 반복: `~/.codex/config.toml`의 `approval_policy`, `sandbox_mode`를 확인한다.
- AGENTS 불일치: 프로젝트 루트 `AGENTS.md -> CLAUDE.md` 심링크를 복구한다.
- 활성화 누락: `nrs` 실행 후 `./scripts/ai/verify-ai-compat.sh`로 재검증한다.
- codex 업데이트가 안 됨: codex는 nix overlay라 버전이 `codex-pin.json`에 핀된다 — 최신화는 `update-codex` 한 줄(자동 추적 아님). `npm install -g @openai/codex`는 `cleanupManualNodeCodex`가 제거하므로 사용하지 않는다 (`whence -p codex`로 PATH 잔재 확인 — nix profile/store 경로여야 정상).

## 투영 아키텍처

```
.claude/skills/<name>/                  # 단일 원본 (SKILL.md, references/ 등)
      -> directory symlink
.agents/skills/<name>/                  # ../../.claude/skills/<name> 심링크
```

Codex CLI는 디렉토리 심링크를 `follow_links(true)`로 순회한다 (PR #8801).
파일 심링크는 무시되므로 반드시 디렉토리 단위로 심링크해야 한다.

## 활성화

원칙은 `nrs` 실행이다.  
환경 제약으로 `nrs`를 실행하지 못하면, Codex 모듈 activation과 동등한 절차로 재생성해도 된다.

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

## 관련 스킬

- `syncing-codex-harness`: 다른 프로젝트에서 Codex 하네스 동기화 시 사용

## 레퍼런스

- 상세 장애 기록 및 회귀 체크: `references/runbook-codex-compat.md`

문서와 CLI 동작이 다를 때는 CLAUDE.md의 "스킬 문서 불일치 시 행동 원칙"을 따른다.
