# recall — Claude Code 세션 아카이브 TUI 열람
# ~/.claude/projects/ + ~/.claude/archive/ 스캔하여 세션 검색/미리보기
{
  inputs,
  pkgs,
  ...
}:

{
  home.packages = [
    inputs.recall.packages.${pkgs.system}.default
  ];
}
