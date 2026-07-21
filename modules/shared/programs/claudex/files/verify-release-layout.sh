#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ] || [ -L "$1" ]; then
  echo "usage: verify-release-layout.sh UNPACKED_DIRECTORY" >&2
  exit 2
fi

shopt -s dotglob nullglob
# 기대 항목의 단일 진실 원천 — 개수 검사·오류 메시지·항목 순회가 모두 이 배열에서 파생된다.
expected_entries=(LICENSE README.md README_CN.md cli-proxy-api config.example.yaml)
entries=("$1"/*)
if [ "${#entries[@]}" -ne "${#expected_entries[@]}" ]; then
  echo "cli-proxy-api: upstream release layout changed (expected ${#expected_entries[@]} entries, found ${#entries[@]}):" >&2
  for entry in "${entries[@]}"; do
    echo "  ${entry##*/}" >&2
  done
  exit 1
fi

for expected in "${expected_entries[@]}"; do
  path="$1/$expected"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    echo "cli-proxy-api: expected a regular release entry: $expected" >&2
    exit 1
  fi
done
