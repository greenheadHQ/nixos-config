# agenix secrets 설정
# 주의: agenix 모듈은 상위(darwin/home.nix, nixos/home.nix)에서 import해야 함
{
  config,
  pkgs,
  lib,
  hostType,
  constants,
  ...
}:

{
  # agenix upstream 무한 재스폰 루프 교정 (launchd KeepAlive 의미론)
  #
  # upstream age-home.nix는 KeepAlive = { Crashed = false; SuccessfulExit = false; }를
  # 선언하는데, launchd.plist(5)에서 Crashed = false는 "crash 시 재시작 안 함"이 아니라
  # "crash가 아닌 종료라면 재시작"(inverse condition)이다. oneshot인 mount 스크립트가
  # exit 0으로 끝나도 non-crash 종료라 조건이 매치되어 무한 재스폰된다
  # (실측: throttle 간격 5~15초, 부팅 세션당 수만 회, stdout 로그 730MB 누적).
  # SuccessfulExit = false(실패 시 재시도)만 남겨 upstream의 재시도 의도는 보존한다.
  # mkForce는 옵션 정의 레벨에서 upstream 정의 전체를 배제하므로 Crashed는 default(null)로
  # 돌아가 plist에서 생략된다.
  launchd.agents.activate-agenix.config.KeepAlive = lib.mkIf pkgs.stdenv.isDarwin (
    lib.mkForce {
      SuccessfulExit = false;
    }
  );

  # agenix generation 위생: stale .tmp 정리 + 심링크 밖 orphan 회수
  # (+ mount point 선생성·Time Machine 제외 provisioning — 본문 서두)
  #
  # nrs.sh의 launchd cleanup이 복호화 중인 agenix agent를 kill하면
  # 0400 권한의 .tmp 파일이 다음 generation 디렉토리에 남는다.
  # 이후 agent 재시작 시 해당 .tmp를 덮어쓸 수 없어 crash loop 발생.
  # setupLaunchAgents 전에 .tmp 잔재 generation과, secretsDir 심링크가
  # 가리키지 않는 orphan generation을 정리한다.
  #
  # 삭제 전 bootout으로 writer와 직렬화한다: .tmp는 "쓰다 만 잔재"만이 아니라
  # "agent가 지금 쓰는 중"의 표시일 수도 있다. 쓰는 중인 generation을 rm -rf하면
  # (a) 삭제 도중 age가 새 파일을 만들어 ENOTEMPTY로 rm이 실패하거나 (2026-08-12
  # nrs 실패 사례 — 당시엔 그 rc가 activation 전체를 중단시켰다), (b) rm이 완성된
  # secret 일부만 지운 뒤 agent가 나머지를 완성·링크해 불완전한 generation이
  # exit 0으로 조용히 배포될 수 있다.
  #
  # bootout 계약은 home-manager launchd 모듈의 bootoutAgent와 동일하게 맞춘다
  # (버전별 종료 완료 보장 + harmless/실패 구분 — bootout은 기본적으로 완료를
  # 기다리지 않고 반환하므로 macOS 26+는 --wait, 이전 버전은 성공 후 1초 대기).
  # "No such process"류는 미로드(=writer 없음)로 통과하고, 그 외 실패는 활성
  # writer가 남았을 수 있으므로 이번 activation에서는 삭제를 건너뛴다 — bootout
  # 실패 후 파괴적 후속 작업을 계속하지 않는 기존 방어 결정(nrs.sh launchd
  # cleanup)과 같은 원칙이다. bootout 성공 후에는 job이 도메인에서 제거되어
  # 재스폰이 불가능하고, setupLaunchAgents는 plist가 unchanged라도 not-loaded
  # job을 다시 bootstrap하므로 ("up-to-date but not loaded" 경로) RunAtLoad 1회
  # 실행이 완전한 fresh generation을 재생성한다. 정리 대상(.tmp 잔재 또는 심링크
  # 밖 orphan)이 없으면 bootout도 하지 않아 정상 경로에는 아무 개입이 없다 —
  # upstream이 매 실행 직전 generation을 지우므로 정상 상태의 mount에는 활성
  # generation 하나만 남아 두 판정 모두 비어 있다.
  #
  # rm 실패는 non-fatal로 남긴다 — bootout 직렬화로 경합은 구조적으로 제거되므로
  # 이제 실패는 예상 밖 이상 신호이지만, 그것이 activation 전체를 중단시킬 이유는
  # 없다 (경고 후 다음 activation에서 재시도).
  home.activation.cleanupAgenixStaleGenerations = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      _agenix_mount="${config.age.secretsMountPoint}"
      # 디렉토리 선생성 + Time Machine sticky 제외 — 구 TMPDIR 위치는 macOS 표준
      # 백업 제외 영역이었지만 홈 아래 영속 위치는 기본 포함이라(tmutil isexcluded
      # 실측), 백업 목적지를 나중에 구성해도 평문 시크릿이 소급 편입되지 않게
      # 구 경로가 무료로 제공하던 제외 계약을 복원한다 (멱등).
      /bin/mkdir -p "$_agenix_mount"
      /usr/bin/tmutil addexclusion "$_agenix_mount" 2>/dev/null || true
      # 가드는 mkdir -p 직후라 항상 참이다 (set -eu에서 mkdir 실패는 여기 도달 전
      # 중단). mkdir 제거·이동 시의 안전망으로 유지한다.
      if [ -d "$_agenix_mount" ]; then
        # 정리 대상 두 종류: (a) .tmp 잔재 generation (쓰다 만/중단), (b) 현재
        # secretsDir 심링크가 가리키지 않는 orphan generation. orphan의 주 발생
        # 경로는 복호화 도중 kill — upstream은 신 generation을 스크립트 서두에
        # 만들고 심링크 전환은 맨 끝이라, 그 사이 전 구간에서 죽으면 링크되지
        # 않은 generation이 남는다 (.tmp 없는 변형 포함: 마지막 secret mv 이후
        # 또는 secret 사이 kill은 이 분기만이 잡는다). 이전 activation의 bootout
        # 실패는 발생 원인이 아니라 잔재가 유지되는 사유다. 롤백 왕복(신→구→신)
        # 잔재는 심링크가 계속 가리키므로 여기 안 걸리고, 신 구성 재적용 시
        # upstream의 직전 generation 삭제가 회수한다. 소비자는 generation 번호가
        # 아니라 안정 심링크(secretsDir)를 경유하므로 심링크가 가리키는
        # generation만 남기면 안전하다. 삭제는 아래 bootout 직렬화 뒤에만 수행한다.
        _active_gen="$(readlink "${config.age.secretsDir}" 2>/dev/null || true)"
        _stale_gens=()
        for _gen_dir in "$_agenix_mount"/*/; do
          [ -d "$_gen_dir" ] || continue
          if /usr/bin/find "$_gen_dir" -name '*.tmp' -maxdepth 1 2>/dev/null | /usr/bin/grep -q .; then
            _stale_gens+=("$_gen_dir")
          elif [ "''${_gen_dir%/}" != "$_active_gen" ]; then
            _stale_gens+=("$_gen_dir")
          fi
        done
        if [ "''${#_stale_gens[@]}" -gt 0 ]; then
          # target은 home-manager 설정을 단일 소스로 조립한다 — domain/Label을
          # literal로 복제하면 upstream이 Label을 바꾸거나 domain을 override한
          # 호스트에서 잘못된 target을 bootout하고, 그 "No such process"가
          # 미로드 성공으로 오인되어 실제 writer를 둔 채 삭제하게 된다.
          _agent_target="${config.launchd.agents.activate-agenix.domain}/$(/usr/bin/id -u)/${config.launchd.agents.activate-agenix.config.Label}"
          _bootout_ok=0
          _bootout_out=""
          if [ "$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)" -ge 26 ]; then
            if _bootout_out="$(/bin/launchctl bootout --wait "$_agent_target" 2>&1)"; then
              _bootout_ok=1
            fi
          else
            if _bootout_out="$(/bin/launchctl bootout "$_agent_target" 2>&1)"; then
              /bin/sleep 1
              _bootout_ok=1
            fi
          fi
          if [ "$_bootout_ok" -ne 1 ]; then
            case "$_bootout_out" in
              *"No such process"* | *"Domain does not support specified action"*)
                _bootout_ok=1 # 미로드 — 활성 writer 없음
                ;;
            esac
          fi
          if [ "$_bootout_ok" -eq 1 ]; then
            for _gen_dir in "''${_stale_gens[@]}"; do
              echo "[agenix] Removing stale/orphan generation: $_gen_dir"
              rm -rf "$_gen_dir" || echo "[agenix] WARNING: could not fully remove $_gen_dir; leaving for next activation"
            done
          else
            echo "[agenix] WARNING: could not bootout agenix agent ($_bootout_out); skipping stale generation cleanup this run"
          fi
        fi
      fi
    ''
  );

  age = {
    # macOS: 복호화 시크릿을 $TMPDIR 밖 영속 위치에 둔다. upstream 기본값
    # $(getconf DARWIN_USER_TEMP_DIR)/agenix{,.d}는 com.apple.bsd.dirhelper가
    # 새벽 03:35에 수행하는 "3일 미접근 파일 청소"의 대상이라, 재부팅 없이도
    # 시크릿이 통째로 사라진다 (2026-08-24 실측: minipc-headless·SA token 등 4건
    # dangling — 재생성 경로는 LaunchAgent RunAtLoad 1회뿐이라 다음 로그인까지
    # 복구 불능, #1094 무인 SSH 우회 사망). 영속 위치의 트레이드오프와 대응:
    # 디스크 잔존 시간 증가는 FileVault 전제 동일(TMPDIR도 재부팅 전까지 디스크
    # 잔존), 파일 0400·디렉토리 0751 권한은 upstream 그대로, Time Machine 기본
    # 포함으로의 반전은 위 cleanup activation의 tmutil addexclusion이 복원한다.
    # 롤백(구 구성 복귀) 시 신 경로에 남는 평문 generation은 구 구성이 이 경로를
    # 모르므로 회수 주체가 없고, 신 구성을 재적용할 때 upstream의 직전 generation
    # 삭제(와 심링크 밖 orphan에 한해 위 cleanup)가 회수한다 — 롤백 상태에 머무는
    # 동안의 수동 회수 절차는 managing-secrets references/troubleshooting.md 참조.
    # linux(MiniPC)는 XDG_RUNTIME_DIR(systemd tmpfs) — dirhelper 문제가 없어 기본값 유지.
    secretsDir = lib.mkIf pkgs.stdenv.isDarwin "${config.home.homeDirectory}/${constants.paths.agenixDarwinSecretsRelPath}";
    secretsMountPoint = lib.mkIf pkgs.stdenv.isDarwin "${config.home.homeDirectory}/${constants.paths.agenixDarwinSecretsRelPath}.d";

    # SSH 키로 복호화
    identityPaths = [ "${config.home.homeDirectory}/.ssh/id_ed25519" ];

    # 공통 시크릿
    secrets = {
      # sharing-text 스킬의 수동 push 함수용 Pushover credentials
      # (Claude Code / Codex hook 알림은 native push로 대체되어 hook은 제거됨.)
      pushover-share = {
        file = ../../../../secrets/pushover-share.age;
        path = "${config.xdg.configHome}/pushover/share";
        mode = "0400";
      };
      # Pane Notepad 링크 파일 (회사 대시보드 등)
      # 사용처: pane-note.sh에서 새 노트 생성 시 Links 섹션에 포함
      pane-note-links = {
        file = ../../../../secrets/pane-note-links.age;
        path = "${config.xdg.configHome}/pane-note/links.txt";
        mode = "0400";
      };
    }
    # Immich CLI 업로드 시크릿은 macOS FolderAction에서 사용
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      immich-api-key = {
        file = ../../../../secrets/immich-api-key.age;
        path = "${config.xdg.configHome}/immich/api-key";
        mode = "0400";
      };
      pushover-immich = {
        file = ../../../../secrets/pushover-immich.age;
        path = "${config.xdg.configHome}/pushover/immich";
        mode = "0400";
      };
      pushover-folder-actions = {
        file = ../../../../secrets/pushover-folder-actions.age;
        path = "${config.xdg.configHome}/pushover/folder-actions";
        mode = "0400";
      };
      shottr-license = {
        file = ../../../../secrets/shottr-license.age;
        path = "${config.xdg.configHome}/shottr/license";
        mode = "0400";
      };
    }
    # #872: Mac 전용 1Password Service Account token (방식 B, epic #780 Phase 2b).
    # 셸 _gh_pat()이 이 토큰으로 github-pat을 무인 발급해 $TMPDIR 캐시에 둔다.
    # personal 호스트에만 배포(개인 Mac 키 recipient) → work role 호스트는 미배포(agenix graceful).
    // lib.optionalAttrs (pkgs.stdenv.isDarwin && hostType == "personal") {
      opnix-service-account-token-mac = {
        file = ../../../../secrets/opnix-service-account-token-mac.age;
        # 경로 단일 소스: constants.onePassword.saTokenMacRelPath — 소비자(gh-pat-mac·op_get)는
        # $HOME 기준으로 같은 상수를 조립하므로 xdg.configHome이 아닌 homeDirectory로 고정한다.
        path = "${config.home.homeDirectory}/${constants.onePassword.saTokenMacRelPath}";
        mode = "0400";
      };
      # 무인 minipc SSH 개인키 (#1094 C안) — ssh minipc-headless alias가 IdentityFile로 사용.
      # 경로 단일 소스: constants.onePassword.headlessKeyRelPath.
      minipc-headless = {
        file = ../../../../secrets/minipc-headless.age;
        path = "${config.home.homeDirectory}/${constants.onePassword.headlessKeyRelPath}";
        mode = "0400";
      };
    };
  };
}
