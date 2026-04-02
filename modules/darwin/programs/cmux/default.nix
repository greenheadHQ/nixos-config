# cmux 설정 (macOS 전용)
{ ... }:

{
  xdg.configFile."cmux/cmux.json".text = builtins.toJSON {
    commands = [ ];
  };
}
