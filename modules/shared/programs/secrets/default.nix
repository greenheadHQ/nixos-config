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
  # agenix crash loop 방지: stale .tmp 파일 정리
  #
  # nrs.sh의 launchd cleanup이 복호화 중인 agenix agent를 kill하면
  # 0400 권한의 .tmp 파일이 다음 generation 디렉토리에 남는다.
  # 이후 agent 재시작 시 해당 .tmp를 덮어쓸 수 없어 crash loop 발생.
  # setupLaunchAgents 전에 깨진 generation을 정리한다.
  home.activation.cleanupAgenixStaleGenerations = lib.mkIf pkgs.stdenv.isDarwin (
    lib.hm.dag.entryBefore [ "setupLaunchAgents" ] ''
      _agenix_mount="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)/agenix.d"
      if [ -d "$_agenix_mount" ]; then
        for _gen_dir in "$_agenix_mount"/*/; do
          if /usr/bin/find "$_gen_dir" -name '*.tmp' -maxdepth 1 2>/dev/null | /usr/bin/grep -q .; then
            echo "[agenix] Removing stale generation with .tmp files: $_gen_dir"
            rm -rf "$_gen_dir"
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
    };
  };
}
