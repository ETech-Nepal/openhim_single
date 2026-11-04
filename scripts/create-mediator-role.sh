#!/usr/bin/env bash
# Creates the OpenHIM role the mediators log in with: register themselves, send
# heartbeats, create and update their channels, nothing else. Idempotent.
# Then create the user mediators@openhim.local in the Console (README).
set -euo pipefail

OPENHIM_API="${OPENHIM_API:-https://localhost:8080}"
read -r -s -p "OpenHIM root@openhim.org password: " OPENHIM_PASSWORD
echo

ROLE='{"name":"mediator-registration","permissions":{
  "mediator-view-all":true,"mediator-manage-all":true,
  "channel-view-all":true,"channel-manage-all":true}}'
him() { curl -kfsS -u "root@openhim.org:$OPENHIM_PASSWORD" -H 'Content-Type: application/json' "$@"; }
if him "$OPENHIM_API/roles/mediator-registration" >/dev/null 2>&1; then
  him -X PUT "$OPENHIM_API/roles/mediator-registration" -d "$ROLE" >/dev/null
else
  him -X POST "$OPENHIM_API/roles" -d "$ROLE" >/dev/null
fi
echo "Role mediator-registration is in place."
