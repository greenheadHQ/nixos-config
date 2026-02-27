# cheat CLI 설정 — 터미널 cheatsheet 즉시 조회
# 사용법: cheat nvim/surround, cheat -l -t neovim, cheat -s ciw
{
  config,
  pkgs,
  nixosConfigPath,
  ...
}:

let
  cheatsheetsPath = "${nixosConfigPath}/modules/shared/programs/cheat/cheatsheets";
  presetsPath = "${nixosConfigPath}/scripts/prompts/presets";
in
{
  home.packages = [ pkgs.cheat ];

  # cheat-browse: wrapper (PROMPT_PRESETS_DIR 주입 + 실행)
  home.file.".local/bin/cheat-browse" = {
    text = ''
      #!/usr/bin/env bash
      export PROMPT_PRESETS_DIR="''${PROMPT_PRESETS_DIR:-${presetsPath}}"
      exec bash "${nixosConfigPath}/modules/shared/programs/cheat/files/scripts/cheat-browse.sh" "$@"
    '';
    executable = true;
  };

  # prompt-render: wrapper (PROMPT_PRESETS_DIR 주입)
  home.file.".local/bin/prompt-render" = {
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      export PROMPT_PRESETS_DIR="''${PROMPT_PRESETS_DIR:-${presetsPath}}"
      exec bash "${nixosConfigPath}/scripts/prompt-render.sh" "$@"
    '';
    executable = true;
  };

  # cheat-browse --prompts에서 사용할 환경변수
  home.sessionVariables.PROMPT_PRESETS_DIR = presetsPath;

  xdg.configFile."cheat/conf.yml".text = ''
    editor: nvim
    colorize: true
    style: monokai
    formatter: terminal256
    pager: less -FRX
    cheatpaths:
      - name: personal
        path: ${cheatsheetsPath}
        tags: [ personal ]
        readonly: false
  '';
}
