#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ] || [ -L "$1" ]; then
  echo "usage: verify-release-layout.sh UNPACKED_DIRECTORY" >&2
  exit 2
fi

shopt -s dotglob nullglob
entries=("$1"/*)
if [ "${#entries[@]}" -ne 5 ]; then
  echo "cli-proxy-api: upstream release layout changed (expected 5 entries, found ${#entries[@]}):" >&2
  for entry in "${entries[@]}"; do
    echo "  ${entry##*/}" >&2
  done
  exit 1
fi

for expected in LICENSE README.md README_CN.md cli-proxy-api config.example.yaml; do
  path="$1/$expected"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    echo "cli-proxy-api: expected a regular release entry: $expected" >&2
    exit 1
  fi
done
