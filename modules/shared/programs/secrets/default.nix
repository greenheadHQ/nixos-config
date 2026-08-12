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
  # rm은 non-fatal: .tmp는 "쓰다 만 잔재"만이 아니라 "agent가 지금 쓰는 중"의 표시일
  # 수도 있어, 쓰기 중인 디렉토리를 rm -rf하면 삭제 도중 새 파일이 생겨 ENOTEMPTY로
  # 실패할 수 있고, 그 rc가 activation 전체를 중단시킨 사례가 있다 (2026-08-12 nrs 실패).
  # 활성 generation을 판별해 제외하는 방식은 쓰지 않는다 — crash loop 잔재는 정확히
  # 활성 번호+1에 남으므로(agent가 readlink+1로 같은 번호를 재사용) 제외하면 본래
  # 목적이 깨진다. 대신 rm이 활성 쓰기와 경합해 지더라도 경고만 남기고, 이긴 경우
  # agent는 실패 종료 후 KeepAlive(SuccessfulExit=false)가 재시도해 자가 회복한다.
  # 위 KeepAlive override로 무한 재스폰이 사라져 activation 시점에 agent가 실행 중인
  # 경우 자체가 드물어졌으므로 경합 확률도 함께 소멸한다.
  home.activation.cleanupAgenixStaleGenerations = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      _agenix_mount="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/agenix.d"
      if [ -d "$_agenix_mount" ]; then
        for _gen_dir in "$_agenix_mount"/*/; do
          if /usr/bin/find "$_gen_dir" -name '*.tmp' -maxdepth 1 2>/dev/null | /usr/bin/grep -q .; then
            echo "[agenix] Removing stale generation with .tmp files: $_gen_dir"
            rm -rf "$_gen_dir" || echo "[agenix] WARNING: could not fully remove $_gen_dir (agent may be writing); leaving for next activation"
          fi
        done
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
