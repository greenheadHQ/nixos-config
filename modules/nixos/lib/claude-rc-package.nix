# claude-rc 사용자 래퍼의 store 패키지 표현식.
#
# Home Manager(home.file 링크)와 NixOS systemd 모듈(claude-rc-maint의
# CLAUDE_RC_BIN)이 같은 인자로 이 표현식을 평가하면 동일 store path를 공유한다.
# systemd ExecStart/env는 절대 store 경로가 필요하므로 (~ 미확장) HM 산출물이
# 아닌 store 패키지로 경계를 통일한다.
# defaultName: 옵션 미지정 수동 실행 시 claude.ai에 표시되는 bridge 이름.
# darwin 배선이 머신별 이름을 주입한다. NixOS의 두 배선(HM/systemd)은 미지정으로
# 같은 기본값을 받아 동일 store path 공유가 유지된다.
{
  pkgs,
  flakePath,
  defaultName ? "minipc",
}:
pkgs.runCommand "claude-rc" { } ''
  install -Dm755 ${
    pkgs.replaceVars ../scripts/claude-rc.sh { inherit flakePath defaultName; }
  } $out/bin/claude-rc
''
