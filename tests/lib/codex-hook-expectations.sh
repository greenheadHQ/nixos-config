#!/usr/bin/env bash
# tests/lib/codex-hook-expectations.sh
# Codex 0.124+ stable hook expectation oracle.
# 본 파일을 source하는 곳:
#   - tests/test-codex-hook-fixtures.sh (fixture runner)
#   - scripts/ai/verify-ai-compat.sh (host-state 검증)
#
# 주의: 본 파일은 test/verifier oracle이며 hook의 runtime source of truth가 아니다.
# hook command / dispatcher sub-script의 실제 정의는 다음 위치에 있다:
#   - modules/shared/programs/codex/files/config.toml         ([[hooks.UserPromptSubmit]] / [[hooks.Stop]] / [[hooks.PreToolUse]] / [[hooks.PostToolUse]])
#   - modules/shared/programs/codex/files/config.darwin.toml  (Darwin 분기)
#   - modules/shared/programs/codex/files/hooks/_stop-dispatcher.sh (sub-script 호출 ordering)
#   - modules/shared/programs/codex/files/hooks/pinning-guard.sh (PreToolUse pinning hard-fail, issue #587)
#   - modules/shared/programs/codex/files/hooks/pinning-alert.sh (PostToolUse pinning warn-only, issue #603)
# hook 추가 / rename 시 위 runtime 파일들과 본 oracle을 함께 수정해야 한다.
# shellcheck disable=SC2034
# (모든 상수가 source caller 측에서만 소비되므로 SC2034 unused 경고를 비활성화한다.)

# stdin schema 기준 라벨 (verbose 표시용)
CODEX_HOOK_SCHEMA_BASELINE="0.124"

# ~/.codex/config.toml의 [[hooks.UserPromptSubmit.hooks]] command. 절대 path는 codex CLI가
# `$HOME` 변수 expansion을 처리하므로 fixture/verifier는 string match로 비교한다.
EXPECTED_USER_PROMPT_COMMAND='$HOME/.codex/hooks/record-prompt-submit.sh'

# ~/.codex/config.toml의 [[hooks.Stop.hooks]] command — 단일 dispatcher.
EXPECTED_STOP_DISPATCHER_COMMAND='$HOME/.codex/hooks/_stop-dispatcher.sh'

# ~/.codex/config.toml의 [[hooks.PreToolUse.hooks]] command — issue #587에서 등록.
# shellcheck disable=SC2016  # $HOME intentionally unexpanded: literal string match against config.toml
EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND='$HOME/.codex/hooks/pinning-guard.sh'

# ~/.codex/config.toml의 [[hooks.PostToolUse.hooks]] command — issue #603에서 등록.
# Codex 0.125 PostToolUse stdin은 apply_patch envelope을 `tool_input.command`로 전달하므로
# hook이 V4A patch text에서 영향 파일과 추가 라인을 직접 파싱한다 (자세한 schema는
# modules/shared/programs/codex/files/hooks/pinning-alert.sh 헤더 주석 참조).
EXPECTED_POST_TOOL_USE_PINNING_COMMAND='$HOME/.codex/hooks/pinning-alert.sh'

# dispatcher가 호출하는 sub-script. ordering은 record-last-stop → nrs-session-cleanup.
# 본 배열 순서는 dispatcher 호출 순서이며 fixture ordering 검증의 expected.
EXPECTED_DISPATCHER_SUB_SCRIPTS=(record-last-stop.sh nrs-session-cleanup.sh)

# live programmatic env inheritance fixture에서 codex-exec-supervised 호출 timeout (hang 방어).
LIVE_CODEX_TIMEOUT_SECONDS=30

# codex-exec-supervised wrapper kill-after grace (issue #593).
# rationale: npm wrapper SIGTERM forward 후 native 응답 대기.
# 본 fixture는 wrapper의 default timeout을 사용하지 않는다 (운영 budget = 30분).
# 대신 invocation matrix 전용 짧은 timeout을 별도 oracle 상수로 둔다.
CODEX_EXEC_KILL_AFTER_SECONDS=5

# invocation matrix fixture default timeout — fixture 안에서 supervisor 발동(timeout 정리)을 검증.
# wrapper default(1800s)와 분리하여 호출자가 fixture 전용 짧은 budget을 명시한다.
INVOCATION_MATRIX_TIMEOUT_SECONDS=40
