# Ghostty 터미널 설정 (macOS 전용)
#
# === Change Intent Record (#1232) ===
# - 로드 순서: macOS Ghostty는 XDG(~/.config/ghostty/config, 아래 xdg.configFile) 다음에
#   ~/Library/Application Support/com.mitchellh.ghostty/config 를 로드하며, 같은 스칼라
#   키는 나중에 읽힌 AppSupport가 이긴다 (upstream src/config/Config.zig loadDefaultFiles).
# - 2026-08 오염 사고: Ghostty 설정 열기(Cmd+, 또는 메뉴) → duti가 public.plain-text 기본
#   앱으로 등록한 VSCode → files.autoSave=afterDelay → 1행 오타 1글자 자동 저장 →
#   "unknown field" 팝업. VSCode Local History 스냅샷 바이트 일치로 확정 (상세 #1232).
# - 점유를 택한 이유: 설정 열기는 keybind 외에 메뉴 항목으로도 살아 있어 봉쇄가 불가능하다.
#   고를 수 있는 것은 "열렸을 때 무엇이 열리는가"뿐이다. 이 슬롯을 비우면 종착지가 nix
#   store의 읽기전용 파일이 되는데, /nix는 read-only 마운트가 아니라 에디터의 권한 상승
#   저장이 성공하면 여러 세대가 하드링크로 공유하는 store 경로가 훼손되고 rebuild로
#   복구되지 않는다. 아래 home.file 안내 스텁으로 점유하면 이 노출 자체가 사라진다.
# - 점유의 한계 (반증 기록): "스텁이 템플릿 재생성을 막는다"는 정당화는 성립하지 않는다 —
#   XDG config와 스텁은 동일 home-manager-files derivation으로 함께 배치/소실된다(상관
#   실패). 재생성 템플릿도 실효 지시어 0줄이라 무해하다. 실가치는 ①설정 열기 종착지가
#   안내문 ②사람이 편집해도 다음 nrs에서 backupCommand 자가치유(modules/darwin/home.nix)
#   ③다른 머신도 선언만으로 수렴, 셋뿐이다.
# - 기각 대안: AppSupport 쪽에 XDG config를 include(config-file 지시어)해 우선순위를
#   뒤집는 안 — include는 항상 마지막에 로드되어 우아해 보이나, font-family 같은
#   repeatable 키가 override가 아니라 append라 fallback chain이 두 배로 쌓인다.
# - 은퇴 조건: 이 스텁은 Ghostty가 legacy 파일명 "config"를 계속 로드한다는 upstream
#   계약에 의존한다. 1.3 문서의 canonical 이름은 config.ghostty다. legacy 지원이 끊기면
#   스텁은 신호 없이 무력화되므로 이 블록 전체를 재검토한다.
# - 불변식: 스텁에 어떤 설정 지시어도 넣지 않는다. 강제 지점은 tests/eval-tests.nix의
#   Test D23c.
{ nixosConfigDefaultPath, ... }:

{
  xdg.configFile."ghostty/config".text = ''
    # 폰트 설정 — Ghostty font-family fallback chain
    #
    # font-family를 여러 줄 지정하면 fallback chain으로 동작한다.
    # 각 문자를 렌더링할 때 1순위 폰트에서 글리프를 먼저 찾고,
    # 없는 경우에만 2순위 이하로 넘어간다.
    #
    # 1순위: JetBrainsMono Nerd Font — 영문/숫자/기호/Nerd Font 아이콘
    # 2순위: D2Coding — 한글 (Nix 설치, 네이버 코딩 전용 폰트)
    font-family = JetBrainsMono Nerd Font
    font-family = D2Coding

    # macOS Option 키를 Alt로 사용 (왼쪽만)
    macos-option-as-alt = left

    # 명령어 완료 알림 (1.3.0+)
    # 포커스되지 않은 창에서 10초 이상 걸린 명령어 완료 시 macOS 알림 전송
    notify-on-command-finish = unfocused
    notify-on-command-finish-action = notify
    # CIR: 10s 선택 — 기본값 5s는 짧은 명령(git push 등)에도 알림이 와서 노이즈 발생
    notify-on-command-finish-after = 10s

    # Split zoom 유지 (1.3.0+)
    # Ghostty 네이티브 split 간 이동 시 zoom 상태 유지
    split-preserve-zoom = navigation

    # SSH integration: 원격 세션에 TERM_PROGRAM/COLORTERM 전달 (yazi SSH 이미지 프리뷰 전제)
    # 출처: https://ghostty.org/docs/features/shell-integration
    # ssh-terminfo는 제외 — MiniPC는 이미 pkgs.ghostty.terminfo 설치됨 (libraries/packages.nix)
    # ssh-terminfo를 켜면 모든 SSH 대상에 tic 원격 실행 발생
    shell-integration-features = ssh-env

    # Shift+Enter로 개행 입력 (TUI 멀티라인)
    # CIR: 2025-07 Claude Code terminal-setup이 Application Support config에 써 둔 줄을
    #   이관 (#1232). 현행 Claude Code는 Ghostty를 네이티브 지원 터미널로 분류해 더는
    #   필요 없지만, kitty keyboard protocol을 쓰지 않는 다른 TUI에는 개행이 전달되지
    #   않을 수 있어 현행 동작 보존을 위해 그대로 옮긴다.
    # 주의: 아래 백슬래시는 이 indented string 안에서만 리터럴로 보존된다. 일반 큰따옴표
    #   문자열이나 concatStringsSep 경유로 리팩터링하면 실제 개행으로 바뀌어 설정이
    #   깨진다. Test D23d가 이 회귀를 막는다.
    keybind = shift+enter=text:\n
  '';

  # Ghostty가 macOS에서 XDG보다 나중에 읽는 슬롯을 Nix가 점유한다 (#1232, 헤더 CIR 참조).
  # 내용은 반드시 주석뿐이어야 한다 — 지시어를 넣는 순간 상위 override 레이어가 부활한다.
  # 주석 전용 파일도 Ghostty가 정상 로드한다 (+validate-config rc 0 실측).
  home.file."Library/Application Support/com.mitchellh.ghostty/config".text = ''
    # 이 파일은 Nix가 관리하는 빈 스텁이다. 읽기 전용이라 직접 편집할 수 없다.
    #
    # Ghostty는 macOS에서 이 경로를 ~/.config/ghostty/config 보다 나중에 읽어
    # 같은 키를 덮어쓴다. 여기에 설정을 두면 Nix 선언이 조용히 무력화되므로
    # 의도적으로 설정 0줄로 유지한다.
    #
    # 실제 설정 소스:
    #   ${nixosConfigDefaultPath}/modules/darwin/programs/ghostty/default.nix
    # 수정 후 nrs로 반영하고, 실행 중인 Ghostty에는 Cmd+Shift+, 로 재적용한다.
    #
    # 값을 시험만 해 보려면 임시 파일에 적어 문법을 확인한 뒤 위 소스로 승격한다.
    #   ghostty +validate-config --config-file=/tmp/ghostty-try.conf
    # 시험 파일을 이 디렉토리에 두지 마라 - 다시 이중 설정이 된다.
    #
    # 이 자리를 비워 두지 않는 이유: 비우면 설정 열기(Cmd+,)가 nix store 안의 읽기
    # 전용 파일을 열게 되고, 거기에 권한을 올려 강제 저장하면 rebuild로도 되돌릴 수
    # 없는 오염이 남는다.
  '';
}
