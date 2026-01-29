# modules/nixos/lib/tailscale-wait.nix
# Tailscale IP가 준비될 때까지 대기하는 systemd ExecStartPre 스크립트
{ pkgs }:

"${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do ${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | grep -q \"^100\\.\" && exit 0; sleep 1; done; echo \"Tailscale IP not ready after 60s\" >&2; exit 1'"
