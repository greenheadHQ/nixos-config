# macOS 키 바인딩 설정 (https://github.com/ttscoff/KeyBindings)
# - ₩ 키 입력 시 ` (백틱) 입력
# - Option+4 입력 시 ₩ (원화) 입력
{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.file."Library/KeyBindings/DefaultKeyBinding.dict".source = ./files/DefaultKeyBinding.dict;
}
