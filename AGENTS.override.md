# Codex CLI 보충 규칙

## 이 파일의 역할

AGENTS.md(= CLAUDE.md 심링크)의 프로젝트 규칙을 모두 따르되, 아래는 Codex 전용 보충이다.

## 스킬 사용

- `.agents/skills/` 에서 스킬이 자동 발견된다
- 스킬의 description과 현재 작업이 매칭되면 SKILL.md를 읽고 따른다

## 도구 차이

- Claude Code의 `/skill-name` 호출은 Codex에서 `$skill-name`에 대응
- Codex hooks는 experimental이며, 이 저장소는 Claude hooks 중 호환 가능한 subset만 project-local `.codex/hooks.json`에 sync하고 진단은 `.codex/hooks.compatibility.json`에 기록한다
- Claude Code plugins와 MCP UI는 Codex에서 직접 대응이 없다

## 빌드

- `nrs` alias 사용. `darwin-rebuild`/`nixos-rebuild` 직접 실행 금지
- nix 관련 명령은 `nix develop` 환경에서 실행 (direnv 자동 활성화)
