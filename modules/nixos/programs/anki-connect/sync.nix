# modules/nixos/programs/anki-connect/sync.nix
# AnkiConnect -> Sync Server 자동 동기화 (on-start + 주기 타이머)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiConnect;
  syncCfg = cfg.sync;
  inherit (constants.network) minipcTailscaleIP;

  syncUrl =
    if syncCfg.url != null then
      syncCfg.url
    else
      "http://${minipcTailscaleIP}:${toString config.homeserver.ankiSync.port}/";
  normalizedSyncUrl = if lib.strings.hasSuffix "/" syncUrl then syncUrl else "${syncUrl}/";

  localAnkiConnectUrl = "http://${minipcTailscaleIP}:${toString cfg.port}";
  localSyncServerEnabled = config.homeserver.ankiSync.enable && syncCfg.url == null;

  syncScript = pkgs.writeShellApplication {
    name = "anki-connect-sync";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      util-linux
    ];
    text = ''
      set -eu

      STATE_FILE="${syncCfg.stateFile}"
      API_URL="${localAnkiConnectUrl}"
      SYNC_ENDPOINT="${normalizedSyncUrl}"
      MAX_RETRIES="${toString syncCfg.maxRetries}"
      BACKOFF_BASE_SEC="${toString syncCfg.backoffBaseSec}"
      LOCK_FILE="/var/lib/anki/.anki-connect-sync.lock"

      mkdir -p "$(dirname "$STATE_FILE")"
      mkdir -p "/var/lib/anki"

      exec 9>"$LOCK_FILE"
      if ! flock -n 9; then
        echo "anki-connect-sync: another sync run is already active, skipping."
        exit 0
      fi

      write_state() {
        now="$1"
        result="$2"
        error="$3"
        last_success="$4"

        jq -n \
          --arg now "$now" \
          --arg result "$result" \
          --arg error "$error" \
          --arg endpoint "$SYNC_ENDPOINT" \
          --arg last_success "$last_success" \
          '{
            lastAttemptAt: $now,
            lastSuccessAt: (if $last_success == "" then null else $last_success end),
            result: $result,
            error: (if $error == "" then null else $error end),
            endpoint: $endpoint
          }' > "$STATE_FILE"
      }

      attempt=1
      delay="$BACKOFF_BASE_SEC"
      last_error=""

      while [ "$attempt" -le "$MAX_RETRIES" ]; do
        started_at="$(date -Iseconds)"
        curl_rc=0
        response="$(
          curl \
            --silent \
            --show-error \
            --max-time 120 \
            --header "Content-Type: application/json" \
            --data '{"action":"sync","version":6}' \
            "$API_URL" 2>&1
        )" || curl_rc=$?

        if [ "$curl_rc" -eq 0 ]; then
          api_error="$(printf '%s' "$response" | jq -r '.error // empty' 2>/dev/null || echo "__parse_error__")"
          if [ "$api_error" = "" ]; then
            write_state "$started_at" "success" "" "$started_at"
            echo "anki-connect-sync: success (attempt $attempt/$MAX_RETRIES)"
            exit 0
          fi
          if [ "$api_error" = "__parse_error__" ]; then
            last_error="invalid sync response: $response"
          else
            last_error="anki-connect error: $api_error"
          fi
        else
          last_error="curl exit $curl_rc: $response"
        fi

        echo "anki-connect-sync: failed (attempt $attempt/$MAX_RETRIES): $last_error"

        if [ "$attempt" -lt "$MAX_RETRIES" ]; then
          sleep "$delay"
          delay="$((delay * 2))"
        fi
        attempt="$((attempt + 1))"
      done

      now="$(date -Iseconds)"
      previous_success="$(jq -r '.lastSuccessAt // empty' "$STATE_FILE" 2>/dev/null || true)"
      write_state "$now" "error" "$last_error" "$previous_success"

      exit 1
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && syncCfg.enable) {
    # headless Anki 프로세스가 읽을 수 있도록 별도 경로에 복호화
    age.secrets.anki-connect-sync-password = {
      file = ../../../../secrets/anki-sync-password.age;
      owner = "anki";
      group = "anki";
      mode = "0400";
    };

    systemd.services.anki-connect-sync = {
      description = "AnkiConnect periodic sync";
      after = [
        "anki-connect.service"
        "network-online.target"
      ]
      ++ lib.optionals localSyncServerEnabled [ "anki-sync-server.service" ];
      wants = [
        "anki-connect.service"
        "network-online.target"
      ]
      ++ lib.optionals localSyncServerEnabled [ "anki-sync-server.service" ];
      partOf = [ "anki-connect.service" ];

      serviceConfig = {
        Type = "oneshot";
        User = "anki";
        Group = "anki";
        ExecStart = "${syncScript}/bin/anki-connect-sync";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };

    systemd.timers.anki-connect-sync = {
      description = "Periodic AnkiConnect sync trigger";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        Unit = "anki-connect-sync.service";
        OnBootSec = "90s";
        OnUnitActiveSec = syncCfg.interval;
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };
  };
}
