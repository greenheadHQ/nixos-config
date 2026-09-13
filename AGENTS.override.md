# Codex CLI 보충 규칙

## 이 파일의 역할

AGENTS.md(= CLAUDE.md 심링크)의 프로젝트 규칙을 모두 따르되, 아래는 Codex 전용 보충이다.

## 스킬 사용

- `.agents/skills/`에서 스킬이 자동 발견된다
- `/skill-name`은 Codex에서 `$skill-name`에 대응

## 도구 차이

- Claude Code 전용 plugin/MCP UI surface는 Codex에서 그대로 대응되지 않는다
- 위임이 승인된 Codex 작업은 현재 세션의 native subagent 도구를 우선한다. 도구 지원과 동시 실행 상한은 현재 세션에 광고된 capability를 확인한다.
- native delegation이 거부되거나 지원되지 않는 경우 subprocess로 우회하지 않는다. 별도 실행은 사용자 승인 범위와 세션의 권한 경계를 따른다.
- `CODEX_CI=1`만으로 세션 유형을 구분하지 않는다.
- SKILL.md의 `allowed-tools` frontmatter는 Codex에서 무시됨

## 사용자 커스텀

### Direct Codex

- tracked workspace write, branch mutation, commit/push, GitHub write는 메인 에이전트 전용이며 explicit delegation만 예외다.
- `wt`/`nrs`/rebuild 계열은 메인 에이전트 전용이다.
- Shared 스킬 노출 정책의 SoT는 [modules/shared/programs/codex/default.nix](modules/shared/programs/codex/default.nix)이며, 독립 감사는 [scripts/ai/verify-ai-compat.sh](scripts/ai/verify-ai-compat.sh)가 수행한다.
- default mode `request_user_input` 활성화/검증 절차는 [.claude/skills/configuring-codex/SKILL.md](.claude/skills/configuring-codex/SKILL.md) 참조. 인터뷰 기반/사용자 확인 단계 스킬은 plain-text 대신 `request_user_input`을 명시적으로 사용한다 (default mode 모델은 자동 호출 안 함).

### 빌드

- `nrs` alias 사용. `darwin-rebuild`/`nixos-rebuild` 직접 실행 금지
- nix 관련 명령은 `nix develop` 환경에서 실행 (direnv 자동 활성화)
- Codex 스킬 노출/정책을 바꾼 뒤에는 `nrs` 후 즉시 `./scripts/ai/verify-ai-compat.sh`로 런타임 surface를 검증한다 (`nrs`가 `~/.codex/skills/*`, `~/.codex/scripts/*` out-of-store symlink를 갱신하므로 repo-local edits만으로는 불충분).
