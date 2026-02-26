# nixpkgs 설정 및 overlay
{ inputs, ... }:

{
  nixpkgs.config = {
    allowUnfree = true;
  };

  # 커스텀 패키지 overlay
  nixpkgs.overlays = [
    # VSCode/Cursor 확장 프로그램 (nix-vscode-extensions)
    inputs.nix-vscode-extensions.overlays.default

    (final: prev: {
      # anki 25.09.2: installCheckPhase에서 libQt6WebChannel.so.6 누락으로 실패 (nixpkgs 버그)
      # Hydra 캐시에 prebuilt 바이너리가 없는 원인이기도 함
      # TODO: 다음 nixpkgs 업데이트 시 이 오버라이드 제거 시도
      anki = prev.anki.overrideAttrs { doInstallCheck = false; };
    })
  ];
}
