# modules/nixos/programs/toss/default.nix
# 토스 자격 증명은 generic opnix 모듈이 아니라 소비자 모듈에서 선언한다.
# githubPat은 기존 예외로 유지하고, 새 토스 시크릿부터 소비 위치가 1Password reference를 소유한다.
{
  config,
  lib,
  constants,
  username,
  ...
}:

let
  opnixCfg = config.homeserver.opnix;
  tossCfg = config.homeserver.toss;
  vault = constants.onePassword.vaults.automation;
  tossOpenApi = constants.onePassword.tossOpenApi;
  opReference = field: "op://${vault}/${tossOpenApi.itemName}/${field}";
in
{
  config = lib.mkIf (opnixCfg.enable && tossCfg.enable) {
    services.onepassword-secrets.secrets = {
      tossClientId = {
        reference = opReference tossOpenApi.clientIdField;
        path = "/run/opnix/${username}/toss-client-id";
        owner = username;
        group = "users";
        mode = "0400";
      };

      tossClientSecret = {
        reference = opReference tossOpenApi.clientSecretField;
        path = "/run/opnix/${username}/toss-client-secret";
        owner = username;
        group = "users";
        mode = "0400";
      };
    };
  };
}
