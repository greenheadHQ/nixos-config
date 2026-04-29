#!/usr/bin/env bash
# tests/lib/codex-hook-expectations.sh
# Codex 0.124+ stable hook expectation oracle.
# 본 파일을 source하는 곳:
#   - tests/test-codex-hook-fixtures.sh (fixture runner)
#   - scripts/ai/verify-ai-compat.sh (host-state 검증)
#
# 주의: 본 파일은 test/verifier oracle이며 hook의 runtime source of truth가 아니다.
# hook command / dispatcher sub-script의 실제 정의는 다음 위치에 있다:
#   - modules/shared/programs/codex/files/config.toml         ([[hooks.UserPromptSubmit]] / [[hooks.Stop]] / [[hooks.PostToolUse]])
#   - modules/shared/programs/codex/files/config.darwin.toml  (Darwin 분기)
#   - modules/shared/programs/codex/files/hooks/_stop-dispatcher.sh (sub-script 호출 ordering)
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

# ~/.codex/config.toml의 [[hooks.PostToolUse.hooks]] command — 본 PR(#603)에서 등록.
# Codex 0.125 PostToolUse stdin은 apply_patch envelope을 `tool_input.command`로 전달하므로
# hook이 V4A patch text에서 영향 파일과 추가 라인을 직접 파싱한다 (자세한 schema는
# modules/shared/programs/codex/files/hooks/pinning-alert.sh 헤더 주석 참조).
EXPECTED_POST_TOOL_USE_PINNING_COMMAND='$HOME/.codex/hooks/pinning-alert.sh'

# dispatcher가 호출하는 sub-script. ordering은 record-last-stop → nrs-session-cleanup →
# stop-notification (issue #590: cleanup이 notification 외부 IPC latency 앞에서 lock 즉시 해제).
# 본 배열 순서는 dispatcher 호출 순서이며 fixture ordering 검증의 expected.
EXPECTED_DISPATCHER_SUB_SCRIPTS=(record-last-stop.sh nrs-session-cleanup.sh stop-notification.sh)

# live env propagation fixture에서 codex exec --ephemeral 호출 timeout (hang 방어).
LIVE_CODEX_TIMEOUT_SECONDS=30
