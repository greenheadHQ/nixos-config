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

  # agenix crash loop 방지: stale .tmp 파일 정리
  #
  # nrs.sh의 launchd cleanup이 복호화 중인 agenix agent를 kill하면
  # 0400 권한의 .tmp 파일이 다음 generation 디렉토리에 남는다.
  # 이후 agent 재시작 시 해당 .tmp를 덮어쓸 수 없어 crash loop 발생.
  # setupLaunchAgents 전에 깨진 generation을 정리한다.
  #
  # 삭제 전 bootout으로 writer와 직렬화한다: .tmp는 "쓰다 만 잔재"만이 아니라
  # "agent가 지금 쓰는 중"의 표시일 수도 있다. 쓰는 중인 generation을 rm -rf하면
  # (a) 삭제 도중 age가 새 파일을 만들어 ENOTEMPTY로 rm이 실패하거나 (2026-08-12
  # nrs 실패 사례 — 당시엔 그 rc가 activation 전체를 중단시켰다), (b) rm이 완성된
  # secret 일부만 지운 뒤 agent가 나머지를 완성·링크해 불완전한 generation이
  # exit 0으로 조용히 배포될 수 있다. bootout이 두 경합을 모두 제거한다 —
  # bootout 후에는 job이 도메인에서 제거되어 재스폰이 불가능하고, home-manager의
  # setupLaunchAgents는 plist가 unchanged라도 not-loaded job은 다시 bootstrap하므로
  # (launchd 모듈의 "up-to-date but not loaded" 경로) RunAtLoad 1회 실행이 완전한
  # fresh generation을 재생성한다. .tmp 잔재가 없으면 bootout도 하지 않아 정상
  # 경로에는 아무 개입이 없다.
  #
  # rm 실패는 non-fatal로 남긴다 — bootout 직렬화로 경합은 구조적으로 제거되므로
  # 이제 실패는 예상 밖 이상 신호이지만, 그것이 activation 전체를 중단시킬 이유는
  # 없다 (경고 후 다음 activation에서 재시도).
  home.activation.cleanupAgenixStaleGenerations = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      _agenix_mount="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/agenix.d"
      if [ -d "$_agenix_mount" ]; then
        _stale_gens=()
        for _gen_dir in "$_agenix_mount"/*/; do
          if /usr/bin/find "$_gen_dir" -name '*.tmp' -maxdepth 1 2>/dev/null | /usr/bin/grep -q .; then
            _stale_gens+=("$_gen_dir")
          fi
        done
        if [ "''${#_stale_gens[@]}" -gt 0 ]; then
          # 쓰는 중일 수 있는 agent를 먼저 내려 rm과 직렬화 (미로드 상태면 무해하게 실패)
          /bin/launchctl bootout "gui/$(/usr/bin/id -u)/org.nix-community.home.activate-agenix" 2>/dev/null || true
          for _gen_dir in "''${_stale_gens[@]}"; do
            echo "[agenix] Removing stale generation with .tmp files: $_gen_dir"
            rm -rf "$_gen_dir" || echo "[agenix] WARNING: could not fully remove $_gen_dir; leaving for next activation"
          done
        fi
      fi
    ''
  );

  age = {
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
