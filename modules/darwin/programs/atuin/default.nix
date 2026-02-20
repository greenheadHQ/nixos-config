{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDir = config.home.homeDirectory;
  atuinFilesPath = "${toString ./.}/files";

  # 모니터링 설정 (Single Source of Truth)
  # 참고: 실제 sync는 atuin 내장 auto_sync가 담당 (sync_frequency = 1m)
  syncCheckInterval = 600; # 10분 (초) - watchdog 상태 체크 주기
  syncThresholdMinutes = 5; # 5분 이상 동기화 안 되면 경고

  # Hammerspoon용 JSON 설정 파일
  monitorConfigJson = builtins.toJSON {
    inherit syncCheckInterval syncThresholdMinutes;
  };
in
{
  # JSON 설정 파일 (Hammerspoon에서 읽기)
  home.file.".config/atuin-monitor/config.json".text = monitorConfigJson;

  # Watchdog 스크립트 배포
  home.file.".local/bin/atuin-watchdog.sh" = {
    source = "${atuinFilesPath}/atuin-watchdog.sh";
    executable = true;
  };

  # launchd 에이전트: Watchdog (동기화 상태 감시 + 알림)
  # 참고: sync 자체는 atuin 내장 auto_sync가 담당하므로, watchdog은 모니터링만 수행
  launchd.agents.atuin-watchdog = {
    enable = true;
    config = {
      Label = "com.green.atuin-watchdog";
      ProgramArguments = [ "${homeDir}/.local/bin/atuin-watchdog.sh" ];
      StartInterval = syncCheckInterval;
      EnvironmentVariables = {
        PATH = "/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin:${homeDir}/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
        HOME = homeDir;
        ATUIN_SYNC_THRESHOLD_MINUTES = toString syncThresholdMinutes;
      };
    };
  };

  # Atuin watchdog alias (macOS 전용)
  home.shellAliases = {
    awd = "~/.local/bin/atuin-watchdog.sh";
  };
}
