# modules/nixos/programs/opnix/default.nix
# opnix — 1Password Service Account 기반 secret materialization (PRD #780 Phase 3)
# Phase 1 stub(SA token 만료일 평문 record 배포)을 extend한다.
#
# brizzbuzz/opnix nixosModules.default(flake.nix에서 import)의 services.onepassword-secrets는
# 1Password Go SDK 기반 root oneshot(op CLI 래퍼 아님)이다. op:// reference를 tmpfs에 native
# materialize하므로 _1password-cli 설치가 불필요하다. opnix-secrets.service가 부팅 시
# 1Password SaaS HTTPS를 호출하므로 컨테이너 secret은 agenix에 영구 잔존한다 (A-3).
{
  config,
  lib,
  constants,
  username,
  ...
}:

let
  cfg = config.homeserver.opnix;
  vault = constants.onePassword.vaults.automation;

  # opnix가 token 접근용으로 생성하는 group. users 옵션을 비워 멤버를 0으로 유지하므로
  # tokenFile이 0640이어도 group으로 읽을 수 있는 user가 없어 실질 root-only다 (PRD #780 결정).
  opnixGroup = "onepassword-secrets";

  # gh PAT를 materialize할 tmpfs 경로 (재부팅 시 휘발 — 평문이 디스크에 영구 잔존하지 않음).
  # user shell의 gh wrapper(shell/nixos.nix)가 GH_TOKEN으로 읽는다.
  ghPatPath = "/run/opnix/${username}/github-pat";
in
{
  config = lib.mkIf cfg.enable {
    # ── Phase 1 stub 보존: SA token 만료일 평문 record 배포 ──
    # Phase 3 rotation timer(opnix-rotate.nix)가 /etc/opnix-service-account-expiry를 읽는다.
    # source 파일: secrets/opnix-service-account-expiry.txt (ISO-8601 date 1줄, agenix 아님).
    environment.etc."opnix-service-account-expiry".source =
      constants.paths.opnixServiceAccountExpirySource;

    # ── SA token (agenix, host key 복호화) ──
    # opnix-secrets.service는 tokenFile을 항상 root:${opnixGroup} 0640으로 강제하므로
    # (opnix nix/module.nix), agenix도 동일 권한으로 선언해 매 activation 권한 경합(토글)을 제거한다.
    # recipient는 minipcHostOnly(host key) — 부팅 의존 시크릿이라 user key 노출 표면과 격리.
    age.secrets.opnix-service-account-token = {
      file = constants.paths.opnixServiceAccountTokenAge;
      mode = "0640";
      owner = "root";
      group = opnixGroup;
    };

    # ── opnix native materialization ──
    services.onepassword-secrets = {
      enable = true;
      tokenFile = config.age.secrets.opnix-service-account-token.path;
      # users 옵션은 의도적으로 미설정 — token group readable이 일반 user로 확산되는 것을 차단.
      secrets.githubPat = {
        # op:// reference. opnix는 secret key에 camelCase만 허용하므로 githubPat (파일명은 path로 지정).
        reference = "op://${vault}/github-pat/token";
        path = ghPatPath;
        owner = username;
        group = "users";
        mode = "0400";
      };
    };

    # materialize 대상의 parent dir을 tmpfs(/run)에 미리 생성한다.
    # opnix processor는 parent를 0755 root로 MkdirAll하지만 이미 존재하면 no-op이므로,
    # tmpfiles가 먼저 0700 ${username}으로 만들어 두면 권한이 보존된다.
    systemd.tmpfiles.rules = [
      "d /run/opnix 0755 root root -"
      "d /run/opnix/${username} 0700 ${username} users -"
    ];
  };
}
