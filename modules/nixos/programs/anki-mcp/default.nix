# modules/nixos/programs/anki-mcp/default.nix
# 원격 MCP 서버 — headless Anki(anki-host) 위의 도구 계층 + 내장 OAuth 2.1 + Cloudflare Tunnel 입구 (plan 030 PR 2a)
#
# === Change Intent Record ===
# 근거(plan 030 결정): E2 입구는 개인 도메인의 Cloudflare Tunnel, U1 내장 인가 서버이며
#   승인 화면만 tailnet 전용 9443, K3 표준 OAuth 2.1(PKCE·PRM·DCR)로 ChatGPT·Codex·Claude가 같은 입구를 쓴다.
# 포트 재설계: Funnel 443은 tailscaled가 peer의 TCP 443을 가로채 Caddy의 기존 4개 vhost를 끊었다.
#   8443은 ChatGPT 자동 OAuth 탐색이 실패했다. 외부 443은 Cloudflare가 받고 로컬 Caddy 443은 보존한다.
# 신뢰 경계: 이 서비스는 이 저장소 최초의 인터넷 공개 입구다. 그래서
#   - 별도 시스템 유저(anki-mcp)로 돌고 Anki 데이터는 파일로 만지지 않는다(AnkiConnect·헬퍼 HTTP만). 컬렉션 디렉터리
#     (anki-host 0700)에 닿을 수 없다 — 취약점이 생겨도 DB 파일을 직접 고치지 못한다.
#   - "지금 동기화" 결과는 결정 15대로 sync 스크립트가 /run 게시판에 남긴 사본(0640, anki-host 그룹)만 읽는다.
#   - sync 유닛 트리거는 polkit 규칙으로 이 유저에게 그 유닛의 start만 허용한다(결정 13). 헬퍼 /sync 직접 호출 없음.
#   - /authorize·승인 폼은 승인 포트에만 있고 공개 앱에는 없다. Tailscale serve 9443이 tailnet 안에서만 그 포트로
#     프록시한다. 승인 포트에 Funnel이 켜져 있으면 해당 serve 경로를 제거한다(STOP 6, fail-closed).
#   - 토큰은 불투명 랜덤값이며 상태 파일에는 해시만 남는다. 승인 문구는 agenix 시크릿(LoadCredential)이고 비어 있으면
#     어떤 승인도 통과하지 않는다.
# 대안 기각: MCP를 anki-host 유저로 실행(DB 직접 접근 가능 — 결정 15 A안으로 기각), 서비스별 API 키(결정 1의 store bake
#   문제 — PR 2에서 재검토 항목으로 남김). Cloudflare에는 단일 터널 실행 credential만 배포한다.
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
  legacyFunnelPort = constants.network.ports.ankiMcpLegacyFunnel;
  approvalPublicPort = constants.network.ports.ankiMcpApprovalPublic;
  publicUrl = "https://${constants.ankiMcp.publicHostname}";
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

  # Tailscale 승인 배선 — serve config는 노드 전역 상태다. 이 유닛이 이전 공개·승인 포트를 소유하고, tailscale.nix의
  # ts-serve 헬퍼(dev 미리보기용)는 constants.network.ports.tailscaleDevPreviewHttps만 만지므로 서로의 config를 덮지 않는다.
  # 이전 8443 Funnel은 제거하고 9443 serve(tailnet 전용) → 승인 포트만 유지한다. 443은 Caddy 전용이다.
  onlineWaitSecs = constants.ankiMcp.tailscaleOnlineWaitSecs;
  cmdTimeoutSecs = constants.ankiMcp.tailscaleCmdTimeoutSecs;
  tsWire = pkgs.writeShellApplication {
    name = "anki-mcp-tailscale-wire";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      # tailscaled가 로그인·온라인 상태가 될 때까지 기다린다 (부팅 직후).
      # CIR: `tailscale status --json | grep -q`는 첫 매치 뒤 grep이 파이프를 닫아 tailscale이 SIGPIPE로 죽고
      #   pipefail이 그걸 실패로 봐서 대기 상한을 매번 꽉 채웠다 — 출력을 변수에 담고 jq로 Self.Online만 본다.
      for _ in $(seq 1 ${toString (onlineWaitSecs / 2)}); do
        status_json="$(tailscale status --json 2>/dev/null || true)"
        if jq -e '.Self.Online == true' >/dev/null 2>&1 <<<"$status_json"; then break; fi
        sleep 2
      done
      # Caddy의 tailnet 443은 그대로 둔다. 다른 설정이 이미 가로채고 있으면 노출을 추가하지 않고 보고한다.
      serve_json="$(tailscale serve status --json)"
      if ! jq -e '.TCP["443"] == null' >/dev/null <<<"$serve_json"; then
        echo "anki-mcp-tailscale: TCP 443 is already intercepted by Tailscale; restore Caddy access before starting MCP" >&2
        exit 1
      fi
      # 이전 릴리스의 인터넷 입구를 먼저 닫는다. 다른 포트와 개발 미리보기는 건드리지 않는다.
      # ExecStop이 이미 지웠거나 새 노드면 off가 "handler does not exist"로 실패하므로 존재할 때만 제거한다.
      if jq -e --arg legacy "${fqdn}:${toString legacyFunnelPort}" '.Web[$legacy].Handlers["/"] != null' >/dev/null <<<"$serve_json"; then
        timeout ${toString cmdTimeoutSecs} tailscale serve --https=${toString legacyFunnelPort} off
      fi
      # CIR: serve/funnel 기능이 tailnet에서 꺼져 있으면 tailscale CLI가 활성화 링크를 찍고 켜질 때까지 무한 대기한다
      #   (oneshot 유닛이 activating에 멈추고 switch가 블록된다) — timeout으로 끊고 fail-closed로 안내한다.
      if ! timeout ${toString cmdTimeoutSecs} tailscale serve --bg --https=${toString approvalPublicPort} "http://127.0.0.1:${toString cfg.approvalPort}"; then
        echo "anki-mcp-tailscale: 'tailscale serve' did not finish — if it printed an enable link, turn on HTTPS/serve for this node in the Tailscale admin console, then 'systemctl restart anki-mcp-tailscale'" >&2
        exit 1
      fi
      serve_json="$(tailscale serve status --json)"
      if jq -e --arg approval "${fqdn}:${toString approvalPublicPort}" '.AllowFunnel[$approval] == true' >/dev/null <<<"$serve_json"; then
        echo "anki-mcp-tailscale: approval port ${toString approvalPublicPort} is exposed to the internet — removing its route (STOP 6)" >&2
        timeout ${toString cmdTimeoutSecs} tailscale serve --https=${toString approvalPublicPort} off
        exit 1
      fi
      if ! jq -e --arg approval "${fqdn}:${toString approvalPublicPort}" '
        .TCP["443"] == null and
        .TCP["${toString legacyFunnelPort}"] == null and .TCP["${toString approvalPublicPort}"].HTTPS == true and
        all((.AllowFunnel // {}) | to_entries[]; .value != true) and
        .Web[$approval].Handlers["/"].Proxy == "http://127.0.0.1:${toString cfg.approvalPort}"
      ' >/dev/null <<<"$serve_json"; then
        echo "anki-mcp-tailscale: approval wiring must be tailnet-only, with no active Funnel and no interception of 443 or the legacy port" >&2
        exit 1
      fi
      echo "anki-mcp-tailscale: ${toString approvalPublicPort} tailnet-only -> 127.0.0.1:${toString cfg.approvalPort}; legacy Funnel removed"
    '';
  };
  # 유닛 정지 시 이 유닛이 켠 두 경로만 끈다 (ts-serve의 미리보기 포트 등 다른 serve 설정은 건드리지 않는다).
  # 종료 중 tailscaled가 먼저 내려가 있을 수 있으므로 각 명령 실패는 무시한다 — 남은 경로는 다음 부팅의 ExecStart가 다시 맞춘다.
  tsUnwire = pkgs.writeShellApplication {
    name = "anki-mcp-tailscale-unwire";
    runtimeInputs = [
      pkgs.tailscale
      pkgs.coreutils
    ];
    text = ''
      # serve off는 해당 포트의 handler와 AllowFunnel도 함께 제거한다.
      timeout ${toString cmdTimeoutSecs} tailscale serve --https=${toString legacyFunnelPort} off || true
      timeout ${toString cmdTimeoutSecs} tailscale serve --https=${toString approvalPublicPort} off || true
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          legacyFunnelPort == 8443
          && !(builtins.elem approvalPublicPort [
            443
            8443
            10000
          ])
          && constants.network.ports.tailscaleDevPreviewHttps != 443
          && constants.network.ports.tailscaleDevPreviewHttps != legacyFunnelPort
          && constants.network.ports.tailscaleDevPreviewHttps != approvalPublicPort;
        message = "homeserver.ankiMcp: reserve 443 for Caddy, remove the legacy 8443 Funnel, and keep approval outside Funnel's allowed ports and separate from dev preview.";
      }
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
          ])
          && !(builtins.elem cfg.approvalPort [
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

    age.secrets.anki-mcp-cloudflared = {
      file = ../../../../secrets/anki-mcp-cloudflared.age;
      owner = "root";
      mode = "0400";
    };
    services.cloudflared = {
      enable = true;
      tunnels.${constants.ankiMcp.tunnelId} = {
        credentialsFile = config.age.secrets.anki-mcp-cloudflared.path;
        ingress.${constants.ankiMcp.publicHostname} = "http://127.0.0.1:${toString cfg.port}";
        default = "http_status:404";
      };
    };
    systemd.services."cloudflared-tunnel-${constants.ankiMcp.tunnelId}" = {
      after = [
        "anki-mcp.service"
        "anki-mcp-tailscale.service"
      ];
      requires = [ "anki-mcp-tailscale.service" ];
      wants = [ "anki-mcp.service" ];
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
      description = "Remote MCP server for headless Anki '${cfg.instance}' (loopback; exposed via Cloudflare Tunnel)";
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
        ANKI_MCP_REFRESH_MAX_ROTATIONS = toString constants.ankiMcp.refreshMaxRotations;
        ANKI_MCP_CODE_TTL_SECS = toString constants.ankiMcp.authCodeTtlSecs;
        ANKI_MCP_SYNC_WAIT_SECS = toString constants.ankiMcp.syncWaitSecs;
        ANKI_MCP_LOCKOUT_FAILURES = toString constants.ankiMcp.approvalLockoutFailures;
        ANKI_MCP_LOCKOUT_SECS = toString constants.ankiMcp.approvalLockoutSecs;
        ANKI_MCP_FIELD_CHARS = toString constants.ankiMcp.fieldCharsDefault;
        ANKI_MCP_PAGE_MAX = toString constants.ankiMcp.pageLimitMax;
        ANKI_MCP_REG_MAX_CLIENTS = toString constants.ankiMcp.registrationMaxClients;
        ANKI_MCP_REG_MAX_CLIENT_BYTES = toString constants.ankiMcp.registrationMaxClientBytes;
        ANKI_MCP_REG_UNUSED_TTL_SECS = toString constants.ankiMcp.registrationUnusedTtlSecs;
        ANKI_MCP_REG_BURST = toString constants.ankiMcp.registrationBurst;
        ANKI_MCP_REG_WINDOW_SECS = toString constants.ankiMcp.registrationWindowSecs;
        ANKI_MCP_MAX_BODY_BYTES = toString constants.ankiMcp.maxRequestBodyBytes;
        ANKI_MCP_BODY_READ_TIMEOUT_SECS = toString constants.ankiMcp.bodyReadTimeoutSecs;
        ANKI_MCP_MAX_CONCURRENCY = toString constants.ankiMcp.maxConcurrentRequests;
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
      description = "Tailscale approval wiring for anki-mcp (${toString approvalPublicPort} tailnet-only; legacy Funnel removed)";
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
        # 멈출 때(모듈 제거·비활성·재시작) 이 유닛이 켠 두 경로만 끈다 — 남은 경로가 나중에 같은 포트를 쓰는 프로세스를 노출하지 않게.
        # 실패해도(tailscaled가 먼저 내려간 종료 중 등) 유닛 정지는 막지 않는다.
        ExecStop = "-${tsUnwire}/bin/anki-mcp-tailscale-unwire";
        # 온라인 대기 + 이전 경로 제거·승인 Serve 설정 두 명령의 상한 + 여유. 스크립트의 timeout이 먼저 끊지만, 이중 안전장치.
        TimeoutStartSec = onlineWaitSecs + 2 * cmdTimeoutSecs + 30;
        TimeoutStopSec = 2 * cmdTimeoutSecs + 10;
      };
    };
  };
}
