# Folder Actions - launchd WatchPaths 기반 폴더 감시
# upload-immich는 Tailscale/Immich 의존이므로 personal 전용 (work Mac은 Tailnet 미소속)
{
  config,
  lib,
  pkgs,
  constants,
  hostType,
  ...
}:

let
  scriptsDir = ./files/scripts;
  homeDir = config.home.homeDirectory;
  folderActionsDir = "${homeDir}/FolderActions";
  shottrDefaultDir = "${homeDir}/${constants.macos.paths.shottrDefaultFolderRelative}";
  logsDir = "${homeDir}/Library/Logs/folder-actions";

  # launchd는 로그인 셸 PATH를 물려받지 않는다. 작업이 직접 호출하는 도구는
  # libraries/packages.nix에 선언한 Nix 패키지 bin으로 연결하고, 나머지는 macOS 시스템
  # 경로만 둔다. Homebrew 경로는 넣지 않는다 — 우연한 외부 설치가 선언을 가린다 (#1402).
  toolJobPath = tools: "${lib.makeBinPath tools}:/usr/bin:/bin";
in
{
  # 스크립트 파일 배치
  home.file = {
    # 공유 헬퍼 (4개 스크립트 source 전용; non-executable)
    ".local/bin/_folder-actions-lib.sh" = {
      source = "${scriptsDir}/_folder-actions-lib.sh";
    };
    ".local/bin/compress-rar.sh" = {
      source = "${scriptsDir}/compress-rar.sh";
      executable = true;
    };
    ".local/bin/compress-video.sh" = {
      source = "${scriptsDir}/compress-video.sh";
      executable = true;
    };
    ".local/bin/rename-asset.sh" = {
      source = "${scriptsDir}/rename-asset.sh";
      executable = true;
    };
    ".local/bin/convert-video-to-gif.sh" = {
      source = "${scriptsDir}/convert-video-to-gif.sh";
      executable = true;
    };
  }
  // lib.optionalAttrs (hostType == "personal") {
    ".local/bin/upload-immich.sh" = {
      source = "${scriptsDir}/upload-immich.sh";
      executable = true;
    };
  };

  # 감시 폴더 생성
  home.activation.createFolderActionsDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "${folderActionsDir}/compress-rar"
    mkdir -p "${folderActionsDir}/compress-video"
    mkdir -p "${folderActionsDir}/rename-asset"
    mkdir -p "${folderActionsDir}/convert-video-to-gif"
    mkdir -p "${shottrDefaultDir}"
    mkdir -p "${logsDir}"
  '';

  # launchd 에이전트 설정
  launchd.agents = {
    # RAR 압축 폴더 감시
    folder-action-compress-rar = {
      enable = true;
      config = {
        Label = "com.greenhead.folder-action.compress-rar";
        ProgramArguments = [ "${homeDir}/.local/bin/compress-rar.sh" ];
        WatchPaths = [ "${folderActionsDir}/compress-rar" ];
        StandardOutPath = "${logsDir}/compress-rar.log";
        StandardErrorPath = "${logsDir}/compress-rar.error.log";
        EnvironmentVariables = {
          PATH = toolJobPath [ pkgs.rar ];
        };
      };
    };

    # 비디오 압축 폴더 감시
    folder-action-compress-video = {
      enable = true;
      config = {
        Label = "com.greenhead.folder-action.compress-video";
        ProgramArguments = [ "${homeDir}/.local/bin/compress-video.sh" ];
        WatchPaths = [ "${folderActionsDir}/compress-video" ];
        StandardOutPath = "${logsDir}/compress-video.log";
        StandardErrorPath = "${logsDir}/compress-video.error.log";
        EnvironmentVariables = {
          PATH = toolJobPath [ pkgs.ffmpeg ];
        };
      };
    };

    # 파일 이름 변경 폴더 감시
    folder-action-rename-asset = {
      enable = true;
      config = {
        Label = "com.greenhead.folder-action.rename-asset";
        ProgramArguments = [ "${homeDir}/.local/bin/rename-asset.sh" ];
        WatchPaths = [ "${folderActionsDir}/rename-asset" ];
        StandardOutPath = "${logsDir}/rename-asset.log";
        StandardErrorPath = "${logsDir}/rename-asset.error.log";
      };
    };

    # 비디오 → GIF 변환 폴더 감시
    folder-action-convert-video-to-gif = {
      enable = true;
      config = {
        Label = "com.greenhead.folder-action.convert-video-to-gif";
        ProgramArguments = [ "${homeDir}/.local/bin/convert-video-to-gif.sh" ];
        WatchPaths = [ "${folderActionsDir}/convert-video-to-gif" ];
        StandardOutPath = "${logsDir}/convert-video-to-gif.log";
        StandardErrorPath = "${logsDir}/convert-video-to-gif.error.log";
        EnvironmentVariables = {
          PATH = toolJobPath [ pkgs.ffmpeg ];
        };
      };
    };
  }
  // lib.optionalAttrs (hostType == "personal") {
    folder-action-upload-immich = {
      enable = true;
      config = {
        Label = "com.greenhead.folder-action.upload-immich";
        ProgramArguments = [ "${homeDir}/.local/bin/upload-immich.sh" ];
        WatchPaths = [ shottrDefaultDir ];
        StandardOutPath = "${logsDir}/upload-immich.log";
        StandardErrorPath = "${logsDir}/upload-immich.error.log";
        # 업로드 실행 시간 제한은 없다. launchd는 TimeOut 키를 구현하지 않는다 (launchd.plist(5)).
        # 멈춘 실행도 저장이 확인되지 않은 원본은 지우지 않으며, 끝내면 다음 실행이 잠금을 회수한다.
        EnvironmentVariables = {
          PATH = "${homeDir}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
          HOME = homeDir;
          IMMICH_INSTANCE_URL = "https://${constants.domain.subdomains.immich}.${constants.domain.base}";
          WATCH_DIR = shottrDefaultDir;
        };
      };
    };
  };
}
