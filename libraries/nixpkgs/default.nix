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
      # 커스텀 패키지 정의
      # myPackage = prev.callPackage ./programs/my-package { };
    })
  ];
}
