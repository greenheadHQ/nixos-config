# shellcheck shell=bash
# runner·sync가 공유하는 검증 계약 — slug 문법과 경로 안전성의 단일 소유처.
# 두 스크립트에 각자 구현하면 discovery(sync)와 execution(runner)이 서로 다른
# 입력을 받아들이는 drift가 생긴다.

# 중립 slug 문법 — 작업 실체를 드러내지 않는 이름만 허용한다.
is_valid_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]
}

# 경로가 "본인 소유·비 symlink·group/world-write 금지"인지 — 실행·스케줄 입력에
# 닿는 모든 구성요소에 적용한다. 최종 파일만 검사하면 상위 디렉터리 교체·symlink로
# 우회된다. 검증~사용 사이의 좁은 TOCTOU 창은 남는다: 이 기기의 위협 모델은
# "다른 로컬 계정이 없는 단일 사용자 호스트"이고, 이 검증의 목적은 실수로 느슨한
# 권한·링크가 생긴 상태를 fail-closed로 드러내는 것이다.
# 반환: 0 정상 / 1 위반 (위반 사유는 stdout — 호출자가 실패 처리 방식을 소유)
path_violation() { # path label → 위반 사유 출력(없으면 빈 출력)
  local path="$1" label="$2" perms
  if [ ! -e "$path" ]; then
    printf '%s missing' "$label"
    return 0
  fi
  if [ -L "$path" ]; then
    printf '%s is a symlink' "$label"
    return 0
  fi
  if [ ! -O "$path" ]; then
    printf '%s not owned by user' "$label"
    return 0
  fi
  perms="$(stat -c %a "$path")"
  if [ $((8#$perms & 8#022)) -ne 0 ]; then
    printf '%s is group/world-writable' "$label"
    return 0
  fi
  return 0
}
