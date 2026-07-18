# Shared Shottr defaults safety bounds. This file is sourced by the manual
# credential refresh helper and inlined into Home Manager activation entries.
# shellcheck shell=bash
# shellcheck disable=SC2034 # Both constants are consumed by sourcing callers.

# These are safety bounds, not tuning knobs. Inherited variables must not
# weaken the outer deadline that contains a possible TCC prompt.
SHOTTR_DEFAULTS_KILL_AFTER=5s
SHOTTR_DEFAULTS_DEADLINE=30s
