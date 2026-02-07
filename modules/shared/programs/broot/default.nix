# broot 설정 (Modern Linux Tree)
{
  config,
  pkgs,
  lib,
  ...
}:

{
  programs.broot = {
    enable = true;
    enableZshIntegration = true; # br 함수 자동 생성

    settings = {
      modal = false; # vim 모드 비활성화 (기본값)

      verbs = [
        {
          # Enter로 파일 선택 시 $EDITOR(nvim)로 열기
          invocation = "edit";
          key = "enter";
          shortcut = "e";
          apply_to = "file";
          execution = "$EDITOR +{line} {file}";
          leave_broot = true;
        }
      ];
    };
  };
}
