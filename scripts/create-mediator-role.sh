#!/usr/bin/env bash
# Creates the limited OpenHIM roles (idempotent):
#   mediator-registration  the mediators: register themselves, send heartbeats, create
#                          and update their channels. User mediators@openhim.local.
#   client-onboarding      the admin portal: view and manage OpenHIM clients.
#                          User admin-portal@openhim.local.
# Then create the users in the Console (README).
set -euo pipefail

OPENHIM_API="${OPENHIM_API:-https://localhost:8080}"
read -r -s -p "OpenHIM root@openhim.org password: " OPENHIM_PASSWORD
echo

him() { curl -kfsS -u "root@openhim.org:$OPENHIM_PASSWORD" -H 'Content-Type: application/json' "$@"; }
role() { # <name> <permissions JSON>
  local body
  body="$(jq -n --arg name "$1" --argjson permissions "$2" '{name: $name, permissions: $permissions}')"
  if him "$OPENHIM_API/roles/$1" >/dev/null 2>&1; then
    him -X PUT "$OPENHIM_API/roles/$1" -d "$body" >/dev/null
  else
    him -X POST "$OPENHIM_API/roles" -d "$body" >/dev/null
  fi
  echo "Role $1 is in place."
}
role mediator-registration '{"mediator-view-all":true,"mediator-manage-all":true,"channel-view-all":true,"channel-manage-all":true}'
role client-onboarding '{"client-view-all":true,"client-manage-all":true}'
