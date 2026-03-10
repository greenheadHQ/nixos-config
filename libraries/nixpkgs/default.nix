# nixpkgs 설정 및 overlay
{ inputs, ... }:

{
  nixpkgs.config = {
    allowUnfree = true;
  };

  # 커스텀 패키지 overlay
  # === Change Intent Record ===
  # v1 (PR #175): anki 25.09.2 installCheckPhase에서 libQt6WebChannel.so.6 누락 빌드 실패
  #   → doInstallCheck=false overlay로 우회. 부작용: derivation 해시 변경 → Hydra 캐시 영구 미스.
  # v2 (PR #183, 이번 변경): nixpkgs upstream에서 버그 수정 확인 (Hydra trunk-combined 빌드 성공)
  #   → overlay 제거하여 Hydra 바이너리 캐시 복원.
  #   trade-off: 향후 nixpkgs 업데이트로 installCheck가 다시 깨지면 overlay를 복원해야 함.
  #             단, nrs dry-run이 소스 빌드를 사전 감지하므로 조기 발견 가능.
  nixpkgs.overlays = [
    # VSCode 확장 프로그램 (nix-vscode-extensions)
    inputs.nix-vscode-extensions.overlays.default
  ];
}
