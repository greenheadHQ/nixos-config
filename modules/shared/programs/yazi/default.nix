# yazi TUI 파일 매니저
# - Ghostty + tmux + SSH 경로에서 Kitty graphics 이미지 프리뷰 전제로 통합
#   (추가 전제: tmux `allow-passthrough on`, Ghostty `shell-integration-features = ssh-env`, sshd `AcceptEnv`)
# - `pkgs.yazi` 래퍼가 file/jq/poppler-utils/7zz/ffmpeg/fd/ripgrep/fzf/zoxide/imagemagick/chafa/resvg를 PATH에 자동 주입
{
  inputs,
  pkgs,
  ...
}:
let
  # 2벌식 한글 IME dual binding for [mgr] 단일 문자 키.
  # preset 의 영문 단일 키 바인딩을 한글 IME 상태에서도 동일 동작하게 미러링.
  # 충돌 규칙: shift 변형이 동일 자모(V→ㅍ = v)인 키는 소문자 우선 (더 자주 사용).
  # shift 더블 자모(Q→ㅃ, O→ㅒ, P→ㅖ) 와 G(g 단독 없음) 는 uppercase 액션에 매핑.
  # 다중 키 시퀀스(gg, m m 등)는 IME 조합 타이밍 불안정으로 제외.
  mkHangul =
    {
      ko,
      run,
      desc,
    }:
    {
      on = [ ko ];
      inherit run desc;
    };
  hangulMgrBindings = map mkHangul [
    # 종료
    {
      ko = "ㅂ";
      run = "quit";
      desc = "Quit the process (한글 IME)";
    }
    {
      ko = "ㅃ";
      run = "quit --no-cwd-file";
      desc = "Quit without outputting cwd-file (한글 IME)";
    }
    # 네비게이션
    {
      ko = "ㅏ";
      run = "arrow prev";
      desc = "Previous file (한글 IME)";
    }
    {
      ko = "ㅓ";
      run = "arrow next";
      desc = "Next file (한글 IME)";
    }
    {
      ko = "ㅎ";
      run = "arrow bot";
      desc = "Go to bottom (한글 IME)";
    }
    {
      ko = "ㅗ";
      run = "leave";
      desc = "Back to the parent directory (한글 IME)";
    }
    {
      ko = "ㅣ";
      run = "enter";
      desc = "Enter the child directory (한글 IME)";
    }
    # 비주얼 모드
    {
      ko = "ㅍ";
      run = "visual_mode";
      desc = "Enter visual mode (한글 IME)";
    }
    # 파일 조작
    {
      ko = "ㅐ";
      run = "open";
      desc = "Open selected files (한글 IME)";
    }
    {
      ko = "ㅒ";
      run = "open --interactive";
      desc = "Open selected files interactively (한글 IME)";
    }
    {
      ko = "ㅛ";
      run = "yank";
      desc = "Yank selected files (copy) (한글 IME)";
    }
    {
      ko = "ㅌ";
      run = "yank --cut";
      desc = "Yank selected files (cut) (한글 IME)";
    }
    {
      ko = "ㅔ";
      run = "paste";
      desc = "Paste yanked files (한글 IME)";
    }
    {
      ko = "ㅖ";
      run = "paste --force";
      desc = "Paste yanked files (overwrite) (한글 IME)";
    }
    {
      ko = "ㅇ";
      run = "remove";
      desc = "Trash selected files (한글 IME)";
    }
    {
      ko = "ㅁ";
      run = "create";
      desc = "Create a file (한글 IME)";
    }
    {
      ko = "ㄱ";
      run = "rename --cursor=before_ext";
      desc = "Rename selected file(s) (한글 IME)";
    }
    # 검색 및 점프
    {
      ko = "ㄴ";
      run = "search --via=fd";
      desc = "Search files by name via fd (한글 IME)";
    }
    {
      ko = "ㅋ";
      run = "plugin fzf";
      desc = "Jump to a file/directory via fzf (한글 IME)";
    }
    {
      ko = "ㄹ";
      run = "filter --smart";
      desc = "Filter files (한글 IME)";
    }
    {
      ko = "ㅜ";
      run = "find_arrow";
      desc = "Next found (한글 IME)";
    }
    # 탭/태스크
    {
      ko = "ㅅ";
      run = "tab_create --current";
      desc = "Create a new tab with CWD (한글 IME)";
    }
    {
      ko = "ㅈ";
      run = "tasks:show";
      desc = "Show task manager (한글 IME)";
    }
  ];
in
{
  programs.yazi = {
    enable = true;
    enableZshIntegration = true;

    # HM stateVersion 25.05 기본값은 "yy" + deprecation warn.
    # 공식 권장값 "y"로 명시 (stateVersion 26.05+ 기본값과 동일).
    shellWrapperName = "y";

    package = pkgs.yazi;

    plugins = {
      inherit (pkgs.yaziPlugins) full-border git starship;
    };

    # catppuccin-mocha flavor: nixpkgs에 yaziFlavors/yaziPlugins.catppuccin-mocha 없어 flake input 사용.
    # path 타입 필요 (HM: attrsOf (oneOf [path package])) → 문자열 interpolation 대신 path 연산.
    flavors.catppuccin-mocha = inputs.yazi-flavors + "/catppuccin-mocha.yazi";
    theme.flavor.dark = "catppuccin-mocha";

    # git.yazi 플러그인 등록: git repo의 파일 목록에 git 상태 linemode 표시.
    # 두 패턴 모두 필요: "*"는 개별 파일, "*/"는 디렉터리 매칭 (git.yazi 공식 README 기준).
    settings.plugin.prepend_fetchers = [
      {
        id = "git";
        url = "*";
        run = "git";
        group = "git";
      }
      {
        id = "git";
        url = "*/";
        run = "git";
        group = "git";
      }
    ];

    # C: cheat-browse (cheat + fzf) 띄우기. nvim <leader>C / tmux prefix+C 와 동일 키로 일관성.
    # preset [mgr] 섹션에 C 단독 바인딩 없음 — 충돌 없음.
    # 절대경로 사용: tmux.conf 의 display-popup 과 동일 규약, PATH 환경 차이에 무관.
    # "ㅊ" 이중 바인딩: 한글 2벌식 IME 활성 시 Shift+C → ㅊ 로 들어오므로 동일 동작 보장.
    keymap.mgr.prepend_keymap = [
      {
        on = [ "C" ];
        run = ''shell "$HOME/.local/bin/cheat-browse" --block'';
        desc = "Browse cheatsheets (cheat + fzf)";
      }
      {
        on = [ "ㅊ" ];
        run = ''shell "$HOME/.local/bin/cheat-browse" --block'';
        desc = "Browse cheatsheets (한글 IME)";
      }
    ]
    ++ hangulMgrBindings;

    # 세 플러그인 모두 명시적 setup 필요 (upstream README 기준).
    initLua = ''
      require("full-border"):setup()
      require("starship"):setup()
      require("git"):setup()
    '';
  };
}
