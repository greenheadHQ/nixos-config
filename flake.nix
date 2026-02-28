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

    # iOS Shortcuts DSL 컴파일러 (Cherri)
    cherri = {
      url = "github:electrikmilk/cherri";
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

      # 두 변수 설계:
      #   nixosConfigPath        — 항상 메인 레포 경로. mkOutOfStoreSymlink 등 ~16곳에서 사용.
      #   nixosConfigDefaultPath — 항상 메인 레포 경로. rebuild-common.sh의 @flakePath@ 전용.
      # Worktree 빌드는 --flake <worktree> 인수로만 처리 (심링크 타깃은 항상 메인 레포).

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
              nixosConfigPath = defaultPath;
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
              nixosConfigPath = defaultPath;
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
            nixpkgs-shared
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
              # worktree 환경에서 공유 config에 남은 core.hooksPath를 정리
              # (lefthook 2.x는 core.hooksPath가 설정되어 있으면 install을 거부함)
              git config --unset-all --local core.hooksPath 2>/dev/null || true
              lefthook install 2>/dev/null || true
            '';
          };
        }
      );
    };
}
