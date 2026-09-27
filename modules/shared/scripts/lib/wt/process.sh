# shellcheck shell=bash
# ── 활성 작업 판정: worktree를 작업 위치(cwd)로 둔 프로세스 ────────────────────
#
# worktree를 지우거나 재생성하기 전에 "누가 이 폴더를 쓰고 있는가"를 본다. 기준은 폴더다 —
# 대상 worktree의 물리 경로와 같거나 그 아래를 cwd로 둔 프로세스는 명령 종류와 무관하게
# 사용 중으로 본다. 유휴 셸도 포함한다: wt는 창을 닫지 않으므로 셸을 통과시키면 사라진
# cwd를 붙잡은 셸이 남는다. 명령 이름으로 예외를 두지 않는 이유도 같다(이름 표기는 바뀐다 —
# lsof는 Claude Code를 버전 문자열로, nix coreutils의 sleep을 "coreutils"로 보고한다).
#
# 판정에서 빼는 것:
#   - wt 자신, 조상 체인 전체, 자손. 조상은 wt를 부른 셸과 세션이다 — worktree에서 시작한
#     에이전트 세션이 저장소 루트로 옮겨 정리할 때 자기 자신 때문에 매번 멈추지 않게 한다.
#     자손은 탐지 명령 자신을 포함한다. 같은 세션이 따로 띄운 백그라운드 셸은 형제라서
#     그대로 잡힌다(막는 쪽이라 안전하다).
#   - 조상 체인이 띄운 caffeinate(부모가 조상이고 argv[0]의 basename이 정확히 caffeinate).
#     Claude Code 세션은 작업 중 caffeinate를 자식으로 계속 새로 띄우고 그 cwd는 세션을
#     시작한 폴더다 — 빼지 않으면 worktree에서 시작한 세션의 정리가 매번 막힌다. caffeinate는
#     잠자기만 막고 파일을 쓰지 않아 지워도 잃을 작업이 없다. 위 "명령 이름으로 예외를 두지
#     않는다"의 유일한 예외이며, 표기가 바뀌면 탐지(막는 쪽)로 돌아간다. 조상 체인의 꼭대기
#     (PID 1)도 조상이라, 부모가 끝나 PID 1로 재부모화된 고아 caffeinate도 빠진다.
#   - 현재 사용자 소유가 아닌 프로세스. 다른 사용자·root 프로세스의 cwd는 권한 없이 읽을 수
#     없고, 읽지 못한 것을 "사용 중"으로 두면 늘 있는 root 프로세스 때문에 매번 막힌다.
#     그래서 "쓰지 않음"으로 본다 — 남는 제약이다.
# 그 밖의 남는 제약: cwd가 worktree 밖인 프로세스(폴더를 열어 둔 GUI 편집기 등)와, 탐지 뒤
# 제거 전에 새로 들어온 프로세스는 보지 못한다. 샌드박스가 다른 프로세스 정보만 가리면
# lsof가 정상 종료하면서 일부만 내므로 가려진 프로세스는 "없음"으로 통과한다(실측).
#
# 수단: lsof로 현재 사용자의 cwd를 한 번에 훑고(-d cwd) 경로로 거른다. 두 플랫폼이 같은
# 파서를 쓰도록 lsof는 wt 래퍼가 Nix store 경로로 고정해 WT_LSOF로 넘긴다 — lsof는 NixOS
# 시스템 PATH에 늘 있지 않다. 없으면 PATH의 lsof를 쓰고, 그것도 없으면 판정 실패다.

# 경로를 lsof 필드 출력(LC_ALL=C)이 이름을 적는 형식으로 바꾼다. lsof는 이름을 날 바이트로
# 내지 않는다 — 실측(lsof 4.99.7, macOS 시스템 lsof도 같음): 0x80 이상 바이트는 소문자
# `\xNN`, 백슬래시는 `\\`, 나머지 출력 가능 ASCII(공백 포함)는 그대로다. 백슬래시도
# 이스케이프되므로 이 변환은 단사다(날 경로의 `\xNN` 글자와 바이트가 섞이지 않는다).
# 제어문자(0x00-0x1f, 0x7f)는 lsof 표기(`\t`·`\n`·`^X` 등)와 맞추지 않고 1을 반환한다.
_wt_lsof_escape_path() {
  local hex byte ch out=""
  hex=$(printf '%s' "$1" | LC_ALL=C od -An -v -tx1) || return 1
  for byte in $hex; do
    case "$byte" in
      5c)       out+='\\' ;;
      [01]?|7f) return 1 ;;
      [89a-f]?) out+="\\x$byte" ;;
      *)        printf -v ch "\\x$byte"; out+="$ch" ;;
    esac
  done
  printf '%s\n' "$out"
}

# 대상 worktree(하위 포함)를 cwd로 둔 프로세스 목록.
# stdout: 판정하면 붙잡은 프로세스마다 "PID<TAB>명령줄" 한 줄(없으면 빈 출력),
#         판정하지 못하면 원인 한 줄.
# 반환: 0 = 판정함, 1 = 판정하지 못함.
_wt_cwd_holders() {
  local wt_path="$1"
  local lsof_bin="${WT_LSOF:-lsof}"
  local target target_name uid scan table rc=0

  # lsof는 물리 경로를 보고한다(macOS에서 /tmp로 들어간 프로세스도 /private/tmp/...).
  # 끝의 x는 경로 끝 개행을 명령 치환이 지우지 않게 하는 표식이다.
  target=$(cd "$wt_path" 2>/dev/null && pwd -P && printf x) || {
    printf 'worktree 경로를 확인하지 못했습니다: %s\n' "$wt_path"
    return 1
  }
  target="${target%$'\n'x}"
  target_name=$(_wt_lsof_escape_path "$target") || {
    printf 'worktree 경로에 제어문자가 있어 lsof 출력과 맞춰 볼 수 없습니다: %q\n' "$target"
    return 1
  }
  if ! command -v "$lsof_bin" >/dev/null 2>&1; then
    printf 'lsof를 찾지 못했습니다: %s\n' "$lsof_bin"
    return 1
  fi
  uid=$(id -u) || { printf '현재 사용자 ID를 읽지 못했습니다\n'; return 1; }

  # LC_ALL=C: 이름 이스케이프가 locale을 따른다(UTF-8이면 한글은 날 바이트, 이모지는
  #   \xNN처럼 섞인다). C로 고정하면 두 플랫폼 출력이 같고 _wt_lsof_escape_path와 맞는다.
  # -a: 선택 조건을 AND로 묶는다(기본은 OR라 -u만으로 cwd 아닌 fd까지 섞인다).
  # -F pn: 필드 출력(PID·이름). f 필드는 lsof 빌드에 따라 함께 나오기도 해서 p·n만 해석한다.
  # -w: 경고(읽지 못한 파일 시스템 등)는 판정과 무관하므로 끈다. 오류는 stderr로 그대로 낸다.
  # -b: 응답 없는 마운트에서 막힐 수 있는 커널 호출(stat·readlink 등)을 피한다. cwd 이름은
  #   macOS는 libproc, Linux는 /proc/<pid>/cwd 링크에서 읽어 이 옵션과 무관하다 — 실제
  #   프로세스 테스트(tests/suites/wt-active-process.sh)가 두 플랫폼에서 이를 지킨다.
  scan=$(LC_ALL=C "$lsof_bin" -w -n -b -a -u "$uid" -d cwd -F pn) || rc=$?
  if (( rc != 0 )); then
    printf 'lsof 실행 실패 (종료 코드 %s)\n' "$rc"
    return 1
  fi

  # 비교 규칙은 "== 대상 또는 대상/로 시작"이다 — feat_a와 feat_ab를 섞지 않는다. 대상도
  # lsof와 같은 표기로 바꿔 비교한다(`/`는 이스케이프되지 않아 경계 규칙이 그대로 선다).
  local line pid="" candidates=""
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}" ;;
      n*)
        if [[ -n "$pid" && ( "${line#n}" == "$target_name" || "${line#n}" == "$target_name/"* ) ]]; then
          candidates+="$pid"$'\n'
        fi
        ;;
    esac
  done <<< "$scan"
  [[ -n "$candidates" ]] || return 0

  # 부모 관계와 명령줄은 ps 한 번으로 얻는다. lsof 뒤에 부르므로 스캔 때 본 프로세스 중
  # 아직 살아 있는 것은 모두 이 표에 있다. 표에 없으면 그 사이 끝난 것이라 건너뛴다.
  table=$(ps -A -ww -o pid=,ppid=,command=) || {
    printf 'ps로 프로세스 관계를 읽지 못했습니다\n'
    return 1
  }
  WT_HOLDER_CANDIDATES="$candidates" awk -v self="$$" '
    function argv0_base(cmd,    w) {
      split(cmd, w, " ")
      sub(/.*\//, "", w[1])
      return w[1]
    }
    {
      cmd = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]*/, "", cmd)
      parent[$1] = $2
      cmdline[$1] = cmd
    }
    END {
      # wt 자신과 조상 체인
      p = self
      while (p != "" && !(p in skip)) {
        skip[p] = 1
        if (!(p in parent)) break
        p = parent[p]
      }
      n = split(ENVIRON["WT_HOLDER_CANDIDATES"], cand, "\n")
      for (i = 1; i <= n; i++) {
        pid = cand[i]
        if (pid == "" || (pid in seen)) continue
        seen[pid] = 1
        if (!(pid in parent) || (pid in skip)) continue
        # 조상 체인이 띄운 caffeinate: argv[0]의 basename이 정확히 caffeinate일 때만 뺀다
        if ((parent[pid] in skip) && argv0_base(cmdline[pid]) == "caffeinate") continue
        # 자손: 부모 사슬을 거슬러 올라가 wt를 만나면 뺀다
        q = pid; hops = 0; descendant = 0
        while ((q in parent) && hops++ < 4096) {
          q = parent[q]
          if (q == self) { descendant = 1; break }
        }
        if (!descendant) printf "%s\t%s\n", pid, cmdline[pid]
      }
    }
  ' <<< "$table"
}

# 활성 작업 가드. 대상 worktree를 cwd로 둔 프로세스가 있거나 판정하지 못하면 안내를 내고
# 0(막음)을 반환한다. 판정하지 못한 것을 "없음"으로 보지 않는다 — 되돌릴 수 없는 작업에서
# 잠금 상태 unknown을 막는 것과 같은 정책이다(fail-closed).
#   label      — 머리말 ("스킵: x", "재생성 불가: x")
#   bypass_cmd — 위험을 알고 진행하는 재실행 명령 (`--yes` 형태)
# 우회 여부는 호출자가 정한다: 이 함수를 부르지 않는 것이 우회다.
_wt_active_process_blocks() {
  local label="$1" wt_path="$2" bypass_cmd="$3"
  local holders pid cmd

  if ! holders=$(_wt_cwd_holders "$wt_path"); then
    _warn "$label (이 worktree를 쓰는 프로세스를 확인하지 못해 멈춥니다 — $holders)"
    _warn "  원인을 해결하고 다시 실행하거나, 위험을 알고 진행하려면: $bypass_cmd"
    return 0
  fi
  [[ -n "$holders" ]] || return 1

  _warn "$label (이 worktree를 작업 위치로 쓰는 프로세스가 있습니다)"
  while IFS=$'\t' read -r pid cmd; do
    _warn "  PID $pid: $cmd"
  done <<< "$holders"
  _warn "  프로세스를 끝낸 뒤 다시 실행하거나, 위험을 알고 진행하려면: $bypass_cmd"
  return 0
}
