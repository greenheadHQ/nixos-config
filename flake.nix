{
  description = "green/nixos-config - macOS & NixOS Development Environment";

  inputs = {
    # === Change Intent Record ===
    # nixpkgs 채널: nixos-unstable-small → nixos-unstable 전환 (2026-03-09)
    # v1: nixos-unstable-small 사용 — 빠른 업데이트 우선
    # v2 (이번 변경): cache hit 최우선 정책으로 전환
    #   대안 1: nixos-unstable-small — 빠르지만 darwin 캐시 보장 안됨 (Mac 소스 빌드 30분+)
    #   대안 2: nixpkgs-unstable — darwin 캐시 우수하나 NixOS 모듈 테스트 없음
    #   대안 3: nixos-24.11 (stable) — 안정적이나 최신 패키지 접근 불가
    #   선택: nixos-unstable — 전체 NixOS 테스트 + Hydra 빌드 시간 충분 → 캐시 커버리지 최대
    #   trade-off: 업데이트가 수일 지연되나, 최신 버전보다 캐시 가용성을 우선하므로 수용.
    #   참고: darwin nrs.sh에는 preflight_source_build_check가 없어,
    #         채널 수준의 캐시 커버리지가 Mac의 1차 방어선임.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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
              # lefthook hook 실행 중(LEFTHOOK=0)에는 재설치 방지 (Issue #125)
              if [ "''${LEFTHOOK:-}" != "0" ]; then
                lefthook install 2>/dev/null || true
              fi
            '';
          };
        }
      );
    };
}
