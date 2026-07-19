# shellcheck shell=bash
# runner·sync가 공유하는 검증 계약 — slug 문법과 경로 안전성의 단일 소유처.
# 두 스크립트에 각자 구현하면 discovery(sync)와 execution(runner)이 서로 다른
# 입력을 받아들이는 drift가 생긴다.

# 중립 slug 문법 — 작업 실체를 드러내지 않는 이름만 허용한다.
is_valid_slug() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]
}

# 경로 안전성 판정 — 위반 사유를 stdout으로 출력한다 (정상이면 빈 출력. 반환값이
# 아니라 출력이 계약이다 — 이름의 "_reason"이 그 계약이다: predicate처럼
# `if path_violation_reason ...`으로 쓰면 항상 참이 된다).
#   type: f(regular file) | d(directory) — owner 소유의 FIFO·디렉터리 오배치도
#         입력 종류 위반으로 잡는다 (head가 정지·즉사하는 경로 차단)
#   denymask: 거부할 권한 비트(8진) — 실행 입력은 022(group/world-write 금지),
#             raw 로그 상태 사슬은 077(0700/0600 계약)
# 검증~사용 사이의 좁은 TOCTOU 창은 남는다: 이 기기의 위협 모델은 "다른 로컬
# 계정이 없는 단일 사용자 호스트"이고, 이 검증의 목적은 실수로 느슨한 권한·링크가
# 생긴 상태를 fail-closed로 드러내는 것이다.
path_violation_reason() { # path label type denymask
  local path="$1" label="$2" type="$3" denymask="$4" perms
  if [ ! -e "$path" ]; then
    printf '%s missing' "$label"
    return 0
  fi
  if [ -L "$path" ]; then
    printf '%s is a symlink' "$label"
    return 0
  fi
  case "$type" in
    f) [ -f "$path" ] || { printf '%s is not a regular file' "$label"; return 0; } ;;
    d) [ -d "$path" ] || { printf '%s is not a directory' "$label"; return 0; } ;;
    *) printf 'internal: unknown type %s' "$type"; return 0 ;;
  esac
  # 필수 접근권 — 금지 비트만 보면 owner가 읽지 못하는 0300 디렉터리가 통과해
  # "작업 0건 발견 → 전체 timer 삭제" 같은 조용한 오동작으로 이어진다.
  if [ ! -r "$path" ]; then
    printf '%s is not readable by owner' "$label"
    return 0
  fi
  if [ "$type" = "d" ] && [ ! -x "$path" ]; then
    printf '%s is not searchable by owner' "$label"
    return 0
  fi
  if [ ! -O "$path" ]; then
    printf '%s not owned by user' "$label"
    return 0
  fi
  perms="$(stat -c %a "$path")"
  if [ $((8#$perms & 8#$denymask)) -ne 0 ]; then
    printf '%s has forbidden permission bits (%s)' "$label" "$perms"
    return 0
  fi
  # canonical 일치 — 마지막 구성요소의 -L 검사는 상위 디렉터리 symlink를 못 본다.
  # 상위 어디든 symlink면 realpath가 달라져 여기서 잡힌다 (raw 로그·unit이 선언
  # 경로 밖으로 흐르는 것 차단).
  if [ "$(realpath "$path")" != "$path" ]; then
    printf '%s resolves outside its declared path' "$label"
    return 0
  fi
  return 0
}
