# libraries/packages.nix
# 공통 패키지 정의 — programs.*.enable으로 관리되지 않는 CLI 도구만 포함
{ pkgs }:

{
  # Darwin + NixOS 공통 CLI 도구
  shared = [
    # 파일/검색 도구
    pkgs.bat # cat 대체 (구문 강조)
    pkgs.eza # ls 대체 (아이콘, 색상)
    pkgs.fd # find 대체 (빠른 파일 검색)
    pkgs.ripgrep # grep 대체 (빠른 텍스트 검색)

    # 개발 도구
    pkgs.shellcheck # 쉘 스크립트 린터

    # 기타 유틸리티
    pkgs.curl # HTTP 클라이언트
    pkgs.jq # JSON 처리
    pkgs.nvd # Nix 변경사항 비교
    pkgs.qrencode # QR 코드 생성 (MiniPC -> iPhone 텍스트 공유)
    pkgs.uv # Python 패키지 관리자
  ];

  # macOS 전용 패키지
  darwinOnly = [
    pkgs.ffmpeg # 미디어 처리
    pkgs.imagemagick # 이미지 처리
    pkgs.rar # 압축
    pkgs.ttyper # 타이핑 연습 CLI
    pkgs.unzip # 압축 해제
  ];

  # NixOS 전용 패키지
  nixosOnly = [
    # TERM 환경변수: SSH 접속 시 클라이언트가 서버에 자신의 터미널 종류를 알리는 값.
    # 서버는 이 값으로 terminfo DB를 조회해 색상, 커서 이동 등 터미널 제어 방법을 결정한다.
    # Mac Ghostty는 TERM=xterm-ghostty를 전달하므로, 서버에 해당 terminfo가 없으면
    # vim/tmux/less 등에서 "unknown terminal type" 에러가 발생한다.
    # Termius 등 다른 SSH 클라이언트는 자체 TERM(보통 xterm-256color)을 사용하므로 무관.
    pkgs.ghostty.terminfo
    pkgs.lm_sensors # 하드웨어 온도 모니터링 (sensors 명령어)
    pkgs.mise # 런타임 버전 관리
  ];
}
