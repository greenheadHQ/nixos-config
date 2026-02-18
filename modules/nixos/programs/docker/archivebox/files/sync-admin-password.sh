#!/usr/bin/env bash
# writeShellApplication provides set -euo pipefail

: "${CONTAINER_NAME:?CONTAINER_NAME is required}"
: "${ADMIN_USERNAME:?ADMIN_USERNAME is required}"
: "${ADMIN_PASSWORD_FILE:?ADMIN_PASSWORD_FILE is required}"
: "${STARTUP_TIMEOUT_SEC:?STARTUP_TIMEOUT_SEC is required}"

if [ ! -s "$ADMIN_PASSWORD_FILE" ]; then
  echo "ArchiveBox admin password file missing or empty: $ADMIN_PASSWORD_FILE" >&2
  exit 1
fi

ADMIN_PASSWORD=$(cat "$ADMIN_PASSWORD_FILE")

# Wait for container runtime readiness (cold boot / restart races).
remaining="$STARTUP_TIMEOUT_SEC"
while [ "$remaining" -gt 0 ]; do
  if podman container inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | rg -q '^true$'; then
    break
  fi
  sleep 1
  remaining=$((remaining - 1))
done

if ! podman container inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null | rg -q '^true$'; then
  echo "ArchiveBox container is not running: $CONTAINER_NAME" >&2
  exit 1
fi

# Pass password via stdin to avoid leaking secret in process args.
if ! podman exec --user archivebox -i -e TARGET_ADMIN_USERNAME="$ADMIN_USERNAME" "$CONTAINER_NAME" /bin/bash -lc '
  IFS= read -r NEW_ADMIN_PASSWORD
  export NEW_ADMIN_PASSWORD
  archivebox manage shell -c "from django.contrib.auth import get_user_model; import os; U=get_user_model(); username=os.environ.get(\"TARGET_ADMIN_USERNAME\", \"admin\"); password=os.environ[\"NEW_ADMIN_PASSWORD\"]; user, created = U.objects.get_or_create(username=username, defaults={\"is_staff\": True, \"is_superuser\": True, \"is_active\": True}); user.set_password(password); user.is_active=True; user.is_staff=True; user.is_superuser=True; user.save(); print(\"created\" if created else \"synced\", username)"
' <<< "$ADMIN_PASSWORD"; then
  echo "ArchiveBox admin password sync failed" >&2
  exit 1
fi

echo "ArchiveBox admin password synced for user: $ADMIN_USERNAME"
