# modules/nixos/programs/anki-host/helper-script.nix
# sync.nix·backup.nix가 공유하는 배선 — 헬퍼 호출 스크립트의 env 집합, Pushover 시크릿·자격 전달 정책, 스크립트 결합.
# 공용 helper-call.sh가 `${VAR:?}`로 요구하는 env는 여기 helperEnv가 단일 소스다 (eval AH8이 세 스크립트 소스의
# `${VAR:?}` 요구 집합과 두 유닛의 environment를 대조한다). 공용 스크립트에 env를 더하면 이 파일만 고친다.
{
  config,
  pkgs,
  constants,
}:
let
  a = constants.ankiHost;
  pushoverCredPath = config.age.secrets.pushover-anki.path;
in
{
  inherit a pushoverCredPath;
  stateRoot = constants.paths.ankiHostState;
  # 준비 대기 최악 = tries × (probe + wait) — 두 유닛 예산의 공통 항
  readyWorstSecs = a.readyWaitTries * (a.readyProbeTimeoutSecs + a.readyWaitSecs);

  # helper-call.sh(준비 대기)와 두 스크립트가 공통으로 요구하는 값 — 스크립트는 env가 없으면 기본값 없이 실패한다
  helperEnv = {
    HELPER_CURL_MAX_TIME = toString a.helperCurlMaxTimeSecs;
    READY_WAIT_TRIES = toString a.readyWaitTries;
    READY_WAIT_SECS = toString a.readyWaitSecs;
    READY_PROBE_TIMEOUT = toString a.readyProbeTimeoutSecs;
    BUSY_RETRIES = toString a.busyRetries;
    BUSY_RETRY_SECS = toString a.busyRetrySecs;
  };

  # Anki 전용 Pushover 앱 토큰 (PUSHOVER_TOKEN=/PUSHOVER_USER=). 두 모듈이 같은 선언을 내고 모듈 시스템이 merge한다
  pushoverSecret = {
    file = ../../../../secrets/pushover-anki.age;
    owner = "root";
    mode = "0400";
  };
  # 자격 전달 정책: root 소유 0400 시크릿을 서비스에 LoadCredential 파일 하나로만 넘긴다 (karakeep-notify 패턴).
  # LoadCredential은 원본 파일이 없으면 유닛이 EXIT_CREDENTIALS(243)로 실패하므로 ConditionPathExists로 막는다 —
  # 시크릿 파일은 placeholder라도 배포와 함께 항상 존재하고(secrets.nix 선언), 값이 빈 경우는 스크립트가 알림 없이 처리한다.
  pushoverCondition = pushoverCredPath;
  pushoverLoadCredential = [ "pushover:${pushoverCredPath}" ];

  # pushover 헬퍼 + 헬퍼 호출 공용 함수 + 본문을 텍스트로 결합한다 (source 경로 주입 대신 store에 고정)
  mkHelperScript =
    name: extraInputs: body:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs =
        with pkgs;
        [
          curl
          jq
          coreutils
        ]
        ++ extraInputs;
      text =
        builtins.readFile ../../../shared/scripts/lib/pushover.sh
        + "\n"
        + builtins.readFile ./files/lib/helper-call.sh
        + "\n"
        + builtins.readFile body;
    };
}
