# modules/nixos/lib/tailscale-wait.nix
# Tailscale IP가 준비될 때까지 대기하는 systemd ExecStartPre 스크립트
{ pkgs }:

pkgs.writeShellScript "wait-for-tailscale-ip" ''
  for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
    if ${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q '^100[.]'; then
      exit 0
    fi
    ${pkgs.coreutils}/bin/sleep 1
  done
  echo "Tailscale IP not ready after 60s" >&2
  exit 1
''
