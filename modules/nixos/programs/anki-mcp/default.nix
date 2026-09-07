# modules/nixos/programs/anki-mcp/default.nix
# 원격 MCP 서버 — headless Anki(anki-host) 위의 도구 계층 + 내장 OAuth 2.1 + Tailscale Funnel 입구 (plan 030 PR 2a)
#
# === Change Intent Record ===
# 근거(plan 030 결정): E1 입구는 Tailscale Funnel(자체 도메인·Cloudflare Tunnel은 공개 확장 시), U1 내장 인가 서버이며
#   승인 화면만 tailnet 전용 8443, K3 표준 OAuth 2.1(PKCE·PRM·DCR)로 ChatGPT·Codex·Claude가 같은 입구를 쓴다.
# 신뢰 경계: 이 서비스는 이 저장소 최초의 인터넷 공개 입구다. 그래서
#   - 별도 시스템 유저(anki-mcp)로 돌고 Anki 데이터는 파일로 만지지 않는다(AnkiConnect·헬퍼 HTTP만). 컬렉션 디렉터리
#     (anki-host 0700)에 닿을 수 없다 — 취약점이 생겨도 DB 파일을 직접 고치지 못한다.
#   - "지금 동기화" 결과는 결정 15대로 sync 스크립트가 /run 게시판에 남긴 사본(0640, anki-host 그룹)만 읽는다.
#   - sync 유닛 트리거는 polkit 규칙으로 이 유저에게 그 유닛의 start만 허용한다(결정 13). 헬퍼 /sync 직접 호출 없음.
#   - /authorize·승인 폼은 승인 포트에만 있고 Funnel 앱에는 없다. Tailscale serve 8443이 tailnet 안에서만 그 포트로
#     프록시한다. anki-mcp-tailscale 유닛은 8443에 Funnel이 켜져 있으면 즉시 끈다(STOP 6, fail-closed).
#   - 토큰은 불투명 랜덤값이며 상태 파일에는 해시만 남는다. 승인 문구는 agenix 시크릿(LoadCredential)이고 비어 있으면
#     어떤 승인도 통과하지 않는다.
# 대안 기각: MCP를 anki-host 유저로 실행(DB 직접 접근 가능 — 결정 15 A안으로 기각), 서비스별 API 키(결정 1의 store bake
#   문제 — PR 2에서 재검토 항목으로 남김), Cloudflare Tunnel(E2 — 공개 확장 시).
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiMcp;
  hostCfg = config.homeserver.ankiHost;
  inherit (constants.ankiMcp) user;
  hostUser = constants.ankiHost.user;
  inst = hostCfg.instances.${cfg.instance};
  fqdn = constants.network.minipcTailnetFqdn;
  approvalPublicPort = constants.network.ports.ankiMcpApprovalPublic;
  publicUrl = "https://${fqdn}";
  approvalUrl = "https://${fqdn}:${toString approvalPublicPort}";
  syncUnit = "anki-host-sync-${cfg.instance}.service";
  statusFile = "${constants.paths.ankiHostStatusRun}/${cfg.instance}.json";
  oauthCredPath = config.age.secrets.anki-mcp-oauth.path;

  # 핀된 nixpkgs의 mcp SDK(1.27.x)와 그 의존만 쓴다 — overlay 없음(PR #183 캐시 사고 재발 방지)
  python = pkgs.python3.withPackages (
    ps: with ps; [
      mcp
      httpx
      uvicorn
      starlette
      pydantic
    ]
  );
  srcDir = ./src;

  # Tailscale serve/funnel 배선 — 노드 전역 상태라 tailscale.nix의 ts-serve 헬퍼(dev 미리보기용)와 별개 유닛으로 둔다.
  # 443 Funnel(인터넷) → MCP 포트, 8443 serve(tailnet 전용) → 승인 포트. 8443에 Funnel이 켜져 있으면 끈다.
  tsWire = pkgs.writeShellApplication {
    name = "anki-mcp-tailscale-wire";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.gnugrep
      pkgs.coreutils
    ];
    text = ''
      # tailscaled가 로그인·온라인 상태가 될 때까지 기다린다 (부팅 직후)
      for _ in $(seq 1 30); do
        if tailscale status --json 2>/dev/null | grep -q '"Online": *true'; then break; fi
        sleep 2
      done
      tailscale serve --bg --https=${toString approvalPublicPort} "http://127.0.0.1:${toString cfg.approvalPort}"
      tailscale funnel --bg --https=443 "http://127.0.0.1:${toString cfg.port}"
      status="$(tailscale funnel status 2>/dev/null || true)"
      if printf '%s\n' "$status" | grep -qE "^https://[^ ]+:${toString approvalPublicPort} .*Funnel on"; then
        echo "anki-mcp-tailscale: approval port ${toString approvalPublicPort} is exposed to the internet — turning Funnel off (STOP 6)" >&2
        tailscale funnel --https=${toString approvalPublicPort} off
        exit 1
      fi
      if ! printf '%s\n' "$status" | grep -qE "^https://${fqdn} \(Funnel on\)"; then
        echo "anki-mcp-tailscale: Funnel on 443 is not active — check the tailnet ACL nodeAttrs funnel (plan 030 Step 16)" >&2
        exit 1
      fi
      echo "anki-mcp-tailscale: 443 funnel -> 127.0.0.1:${toString cfg.port}, ${toString approvalPublicPort} tailnet-only -> 127.0.0.1:${toString cfg.approvalPort}"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hostCfg.enable && (hostCfg.instances ? ${cfg.instance}) && inst.sync.enable;
        message = "homeserver.ankiMcp: instance '${cfg.instance}' must exist in homeserver.ankiHost.instances with sync.enable (the MCP host is the AnkiWeb-synced instance).";
      }
      {
        assertion =
          cfg.port != cfg.approvalPort
          && !(builtins.elem cfg.port [
            inst.port
            inst.helperPort
          ]);
        message = "homeserver.ankiMcp: port/approvalPort must be distinct from each other and from the instance's AnkiConnect/helper ports.";
      }
    ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      # 결정 15: /run 게시판의 상태 사본(0640, anki-host 그룹)을 읽기 위한 그룹 — 컬렉션 디렉터리는 0700이라 여전히 닿지 않는다
      extraGroups = [ hostUser ];
    };
    users.groups.${user} = { };

    # 승인 문구 (ANKI_MCP_APPROVAL_PASSPHRASE=). root 0400 → 유닛에는 LoadCredential 파일로만 전달
    age.secrets.anki-mcp-oauth = {
      file = ../../../../secrets/anki-mcp-oauth.age;
      owner = "root";
      mode = "0400";
    };

    # 결정 13: "지금 동기화"는 헬퍼가 아니라 sync 유닛을 트리거한다 — 이 유저에게 그 유닛의 start만 허용
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "${syncUnit}" &&
            action.lookup("verb") == "start" &&
            subject.user == "${user}") {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.services.anki-mcp = {
      description = "Remote MCP server for headless Anki '${cfg.instance}' (loopback; exposed via Tailscale Funnel)";
      after = [
        "anki-host-${cfg.instance}.service"
        "network-online.target"
      ];
      wants = [
        "anki-host-${cfg.instance}.service"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        PYTHONPATH = "${srcDir}";
        PYTHONUNBUFFERED = "1";
        ANKI_MCP_PORT = toString cfg.port;
        ANKI_MCP_APPROVAL_PORT = toString cfg.approvalPort;
        ANKI_MCP_PUBLIC_URL = publicUrl;
        ANKI_MCP_APPROVAL_URL = approvalUrl;
        ANKI_CONNECT_URL = "http://127.0.0.1:${toString inst.port}";
        ANKI_HELPER_URL = "http://127.0.0.1:${toString inst.helperPort}";
        ANKI_SYNC_STATUS_FILE = statusFile;
        ANKI_SYNC_UNIT = syncUnit;
        ANKI_MCP_ACCESS_TTL_SECS = toString constants.ankiMcp.accessTokenTtlSecs;
        ANKI_MCP_REFRESH_TTL_SECS = toString constants.ankiMcp.refreshTokenTtlSecs;
        ANKI_MCP_CODE_TTL_SECS = toString constants.ankiMcp.authCodeTtlSecs;
        ANKI_MCP_SYNC_WAIT_SECS = toString constants.ankiMcp.syncWaitSecs;
        ANKI_MCP_LOCKOUT_FAILURES = toString constants.ankiMcp.approvalLockoutFailures;
        ANKI_MCP_LOCKOUT_SECS = toString constants.ankiMcp.approvalLockoutSecs;
        ANKI_MCP_FIELD_CHARS = toString constants.ankiMcp.fieldCharsDefault;
        ANKI_MCP_PAGE_MAX = toString constants.ankiMcp.pageLimitMax;
      };

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = user;
        StateDirectory = "anki-mcp";
        StateDirectoryMode = "0700";
        LoadCredential = [ "approval:${oauthCredPath}" ];
        ExecStart = "${python}/bin/python -m anki_mcp";
        Restart = "on-failure";
        RestartSec = 10;
        TimeoutStopSec = 30;
        MemoryMax = "256M";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
      path = [ pkgs.systemd ]; # systemctl show/start (polkit)
    };

    systemd.services.anki-mcp-tailscale = {
      description = "Tailscale Funnel/serve wiring for anki-mcp (443 funnel -> MCP, 8443 tailnet-only -> approval)";
      after = [
        "tailscaled.service"
        "anki-mcp.service"
      ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tsWire}/bin/anki-mcp-tailscale-wire";
      };
    };
  };
}
