#!/usr/bin/env bash
# 셸 startup 측정 — opt-in 재현용(repro) 벤치. 회귀 게이트가 아니다 (lefthook/CI 미배선).
#
# 레퍼런스 "Life is too short for a slow terminal"
# (https://mijndertstuij.nl/posts/life-is-too-short-for-a-slow-terminal/)의 핵심 처방(측정)을 재현한다.
# 절대 ms가 시스템 부하(관찰자 효과)로 크게 흔들려 hard-gate(pre-push/CI 차단)에는
# 부적합하다 — min/구조적 비교 위주로 해석한다. 회귀의 결정론적 lock은
# tests/eval-tests.nix의 구조 불변식(Test D10~D12)이 담당하며, 이 스크립트는 게이트 책임을 지지 않는다.
#
# 사용: bash tests/bench-shell-startup.sh
#
# hyperfine은 프로젝트 flake.lock의 nixpkgs pin에서 주입한다(레지스트리 fetch·pin 우회 없음;
# profile fallback과 같은 `nix shell --inputs-from .` pinning 패턴).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

cat <<'EOF'
== 인터랙티브 zsh startup 측정 (zsh -i -c exit) ==
주의:
  - 이 측정은 rc-sourcing(.zshenv + .zshrc)만 잰다. 사용자가 체감하는 first-prompt /
    input latency와는 다르다 — precmd 훅·zle 위젯·direnv devShell 평가는
    'zsh -i -c exit'에서 발화하지 않아 미포함이다.
  - 절대 ms는 시스템 부하에 민감하다. 동일 부하에서의 전후(nrs 적용 전/후) 비교,
    또는 min을 구조 지표로 본다.

EOF

exec nix shell --inputs-from . nixpkgs#hyperfine --command \
  hyperfine --warmup 3 --runs 20 'zsh -i -c exit'
