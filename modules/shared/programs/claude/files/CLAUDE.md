# User-scope Instructions

## Description Optimization Override

skill description optimization 시 skill-creator 플러그인의 `improve_description.py` 대신 `~/.claude/scripts/improve-description.sh`를 사용하라.
이 스크립트는 `claude -p`를 사용하여 ANTHROPIC_API_KEY가 불필요하다.

> 배경: 로컬 캐시된 skill-creator 플러그인이 구버전(Anthropic SDK 직접 호출)이라 API 키가 필요함.
> GitHub main에는 이미 claude -p 전환이 완료되었으나 플러그인 릴리스에 미반영.
> 플러그인이 업데이트되면 이 Override는 제거 가능. (#281)
