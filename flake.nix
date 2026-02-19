{
  description = "green/nixos-config - macOS & NixOS Development Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Age 기반 secrets 관리 (agenix)
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "nix-darwin";
      inputs.home-manager.follows = "home-manager";
    };

    # VSCode/Cursor 확장 프로그램 관리
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # NixOS 디스크 파티셔닝
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-darwin,
      home-manager,
      disko,
      ...
    }@inputs:
    let
      # 공유 라이브러리
      constants = import ./libraries/constants.nix;
      nixpkgs-shared = ./libraries/nixpkgs;

      # 다중 시스템 지원
      systems = {
        darwin = "aarch64-darwin";
        linux = "x86_64-linux";
      };

      # 워크스페이스 디렉토리명 (~/Workspace/nixos-config)
      # 단일 관리 포인트: 여기만 변경하면 nixosConfigPath + rebuild-common.sh FLAKE_PATH 자동 반영
      workspaceDir = "Workspace";

      # Worktree 지원: nrs가 --impure로 빌드 시 env var로 nixosConfigPath 오버라이드
      # pure mode(기본)에서는 ""을 반환하여 defaultPath 사용
      nixosConfigPathOverride = builtins.getEnv "NIXOS_CONFIG_PATH";

      # 두 변수 설계:
      #   nixosConfigPath      — 동적 (worktree 경로 or 메인 레포). mkOutOfStoreSymlink 등 대부분의 소비자가 사용.
      #   nixosConfigDefaultPath — 항상 메인 레포. rebuild-common.sh의 @flakePath@ 전용.
      # nixosConfigPath를 동적으로 만든 이유: mkOutOfStoreSymlink 소비자 ~16곳의 코드 변경을 0으로 유지하기 위함.
      # 반대로 nixosConfigPath를 고정하고 새 동적 변수를 도입하면, ~16곳 모두 변수명 교체 필요.

      # macOS 호스트 설정 (확인: scutil --get LocalHostName)
      darwinHosts =
        let
          mkDarwinHost =
            username: hostType:
            let
              defaultPath = "/Users/${username}/${workspaceDir}/nixos-config";
            in
            {
              inherit username hostType;
              nixosConfigPath = if nixosConfigPathOverride != "" then nixosConfigPathOverride else defaultPath;
              nixosConfigDefaultPath = defaultPath;
            };
        in
        {
          "greenhead-MacBookPro" = mkDarwinHost "green" "personal";
          "work-MacBookPro" = mkDarwinHost "glen" "work";
        };

      # NixOS 호스트 설정
      nixosHosts =
        let
          mkNixosHost =
            username: hostType:
            let
              defaultPath = "/home/${username}/${workspaceDir}/nixos-config";
            in
            {
              inherit username hostType;
              nixosConfigPath = if nixosConfigPathOverride != "" then nixosConfigPathOverride else defaultPath;
              nixosConfigDefaultPath = defaultPath;
            };
        in
        {
          "greenhead-minipc" = mkNixosHost "greenhead" "server";
        };

      # darwinConfiguration 생성 함수
      mkDarwinConfig =
        hostname: hostConfig:
        nix-darwin.lib.darwinSystem {
          system = systems.darwin;
          modules = [
            nixpkgs-shared
            home-manager.darwinModules.home-manager
            ./modules/shared/configuration.nix
            ./modules/darwin/configuration.nix
            ./modules/darwin/home.nix
          ];
          specialArgs = {
            inherit inputs hostname constants;
            inherit (hostConfig)
              username
              hostType
              nixosConfigPath
              nixosConfigDefaultPath
              ;
          };
        };

      # nixosConfiguration 생성 함수
      mkNixosConfig =
        hostname: hostConfig:
        nixpkgs.lib.nixosSystem {
          system = systems.linux;
          modules = [
            inputs.agenix.nixosModules.default
            disko.nixosModules.disko
            home-manager.nixosModules.home-manager
            ./modules/shared/configuration.nix
            ./hosts/${hostname}
            ./modules/nixos/configuration.nix
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                backupFileExtension = "backup";
                extraSpecialArgs = {
                  inherit inputs hostname constants;
                  inherit (hostConfig)
                    username
                    hostType
                    nixosConfigPath
                    nixosConfigDefaultPath
                    ;
                };
                users.${hostConfig.username} = import ./modules/nixos/home.nix;
              };
            }
          ];
          specialArgs = {
            inherit inputs hostname constants;
            inherit (hostConfig)
              username
              hostType
              nixosConfigPath
              nixosConfigDefaultPath
              ;
          };
        };

    in
    {
      # macOS 설정
      darwinConfigurations = builtins.mapAttrs mkDarwinConfig darwinHosts;

      # NixOS 설정
      nixosConfigurations = builtins.mapAttrs mkNixosConfig nixosHosts;

      # 개발 쉘 (다중 시스템)
      devShells = nixpkgs.lib.genAttrs [ systems.darwin systems.linux ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              nixfmt
              lefthook
              gitleaks
              shellcheck
              inputs.agenix.packages.${system}.default
            ];
            shellHook = ''
              lefthook install 2>/dev/null || true
            '';
          };
        }
      );
    };
}
