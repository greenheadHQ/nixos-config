# agent-browser 설치 (공통: macOS + NixOS)
# 런타임 의존성: Node.js (mise가 관리), Chromium (Playwright가 관리)
{ pkgs, lib, ... }:
{
  # npm global prefix 경로를 PATH에 추가
  home.sessionPath = [ "$HOME/.npm-global/bin" ];

  # npm global install로 agent-browser + Chromium 설치
  home.activation.installAgentBrowser = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export npm_config_prefix="$HOME/.npm-global"
    export PATH="${pkgs.nodejs}/bin:$PATH"
    mkdir -p "$HOME/.npm-global"

    if [ ! -f "$HOME/.npm-global/bin/agent-browser" ]; then
      echo "Installing agent-browser..."
      ${pkgs.nodejs}/bin/npm install -g agent-browser

      echo "Installing Chromium for agent-browser..."
      ${pkgs.nodejs}/bin/npx playwright install chromium
    else
      echo "agent-browser already installed at $HOME/.npm-global/bin/agent-browser"
    fi
  '';
}
