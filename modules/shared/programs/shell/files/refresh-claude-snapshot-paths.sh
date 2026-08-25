#!/usr/bin/env bash
# vendor는 snapshot의 `export PATH=`에 zsh 평가 결과가 아니라 claude 프로세스의
# env PATH를 리터럴 기록한다 (2026-08-24 실측, darwin.nix .zshenv 주석 참조).
# 터미널 기원 claude의 snapshot에는 dispatcher가 없어 이 멱등 append가 그 층의
# 방어이고, claude-rc 계열 기원은 launcher가 주입한 env PATH 상속으로 vendor
# 라인에 이미 dispatcher가 있을 수 있다(아래 둘째 grep이 skip). 두 호출자가
# 배선한다: home.activation(nrs 시점 일괄)과 launchd WatchPaths agent(상시).
#
# 구현 계약 (WatchPaths 자기 재발화 방지): 이 스크립트는 기존 파일에 대한
# append만 수행해야 한다. 파일 생성/rename/삭제는 감시 디렉토리의 vnode를 바꿔
# WatchPaths agent를 다시 발화시키는 자기 루프를 만든다 (darwin.nix agent 주석).
set -u

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <snapshot-dir> <dispatcher-bin>\n' "$0" >&2
  exit 2
fi

snapshot_dir="$1"
dispatcher_bin="$2"
marker="# nixos-config headless SSH PATH recovery v1"

case "$dispatcher_bin" in
  /*) ;;
  *)
    printf 'refresh-claude-snapshot-paths: dispatcher path must be absolute\n' >&2
    exit 2
    ;;
esac

[ -d "$snapshot_dir" ] || exit 0

for snapshot in "$snapshot_dir"/snapshot-zsh-*.sh; do
  [ -f "$snapshot" ] || continue
  [ ! -L "$snapshot" ] || continue

  # 판정은 grep 2회로 한다 — bash while-read 전량 루프는 launchd 상시 경로에서
  # 이벤트당 초 단위 비용이었다 (실측 30파일/2.9MB에 2.9초 → grep은 밀리초).
  # 첫 grep: 마커 라인 exact match. 둘째 grep: export PATH= 라인 중 dispatcher 포함.
  grep -aqxF "$marker" "$snapshot" && continue
  grep -a "^export PATH=" "$snapshot" | grep -qF -- "$dispatcher_bin" && continue

  # One append preserves the vendor snapshot and lets in-flight readers either
  # finish on the old EOF or observe the complete recovery block next time.
  if ! printf '%s\n' \
    "$marker" \
    "export PATH=\"$dispatcher_bin:\$PATH\"" \
    >> "$snapshot"
  then
    printf 'refresh-claude-snapshot-paths: warning: could not update %s\n' "$snapshot" >&2
  fi
done
