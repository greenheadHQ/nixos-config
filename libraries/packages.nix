# libraries/packages.nix
# 공통 패키지 정의 (lib 스타일 - 명시적 pkgs.* 참조로 출처 추적 용이)
{ pkgs }:

{
  # Darwin + NixOS 공통 CLI 도구
  shared = [
    # 파일/검색 도구
    pkgs.bat # cat 대체 (구문 강조)
    pkgs.eza # ls 대체 (아이콘, 색상)
    pkgs.fd # find 대체 (빠른 파일 검색)
    pkgs.fzf # fuzzy finder
    pkgs.ripgrep # grep 대체 (빠른 텍스트 검색)
    pkgs.zoxide # cd 대체 (디렉토리 점프)

    # 개발 도구
    pkgs.tmux # 터미널 멀티플렉서
    pkgs.gh # GitHub CLI
    pkgs.git # 버전 관리
    pkgs.shellcheck # 쉘 스크립트 린터

    # 쉘 도구
    pkgs.starship # 프롬프트 커스터마이징
    pkgs.atuin # 쉘 히스토리 동기화

    # 기타 유틸리티
    pkgs.curl # HTTP 클라이언트
    pkgs.jq # JSON 처리
    pkgs.htop # 시스템 모니터링
    pkgs.nvd # Nix 변경사항 비교
    pkgs.qrencode # QR 코드 생성 (MiniPC -> iPhone 텍스트 공유)
    pkgs.uv # Python 패키지 관리자 (Astral ty LSP의 uvx 의존성)
  ];

  # macOS 전용 패키지
  darwinOnly = [
    pkgs.broot # 파일 탐색기 TUI
    pkgs.ffmpeg # 미디어 처리
    pkgs.imagemagick # 이미지 처리
    pkgs.rar # 압축
    pkgs.ttyper # 타이핑 연습 CLI
    pkgs.unzip # 압축 해제
  ];

  # NixOS 전용 패키지
  nixosOnly = [
    pkgs.ghostty # Terminfo (SSH 접속 시 필요)
    pkgs.mise # 런타임 버전 관리
    pkgs.mosh # 모바일 쉘 (불안정한 네트워크용)
  ];
}
