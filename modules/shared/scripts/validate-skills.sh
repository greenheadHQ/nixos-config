#!/bin/bash
# validate-skills.sh - Claude Code 스킬 유효성 검사 도구
#
# 용도: .claude/skills/*/SKILL.md 파일들의 YAML 프론트매터를 검증
#       - YAML 구문 검증 (name, description 필드)
#       - description 길이 검증 (150-260자)
#
# 의존성: yq (brew install yq 또는 nix-shell -p yq)
# 참고: 이 스크립트는 Nix 설정에서 참조되지 않음 (수동 실행용)

set -euo pipefail

echo "=== Skills Validation ==="
echo "Date: $(date)"
echo

# 의존성 체크
command -v yq >/dev/null 2>&1 || { echo "Error: yq required. Install: brew install yq"; exit 1; }

echo "## 1. YAML 구문 검증"
for f in .claude/skills/*/SKILL.md; do
  if sed -n '2,/^---$/p' "$f" | head -n -1 | yq -e '.name, .description' > /dev/null 2>&1; then
    echo "✅ $(basename "$(dirname "$f")")"
  else
    echo "❌ $(basename "$(dirname "$f")")"
  fi
done

echo
echo "## 2. 길이 검증 (150-260자)"
for f in .claude/skills/*/SKILL.md; do
  name=$(basename "$(dirname "$f")")
  if ! description=$(sed -n '2,/^---$/p' "$f" | head -n -1 | yq -r '.description'); then
    echo "❌ $name: YAML .description 파싱 실패"
    continue
  fi
  len=$(printf '%s\n' "$description" | wc -c)
  if [ "$len" -lt 150 ] || [ "$len" -gt 260 ]; then
    echo "⚠️  $name: ${len}자 (범위 초과)"
  else
    echo "✅ $name: ${len}자"
  fi
done
