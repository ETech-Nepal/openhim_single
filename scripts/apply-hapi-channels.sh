#!/usr/bin/env bash
# Creates or updates the OpenHIM channels that route /fhir reads and single-resource
# writes straight to HAPI (openhim-config/hapi-channels.json). HAPI has no mediator to
# register them, so this runs once per deployment and after every change. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENHIM_API="${OPENHIM_API:-https://localhost:8080}"
read -r -s -p "OpenHIM root@openhim.org password: " OPENHIM_PASSWORD
echo

him() { curl -kfsS -u "root@openhim.org:$OPENHIM_PASSWORD" -H 'Content-Type: application/json' "$@"; }
existing="$(him "$OPENHIM_API/channels")"
jq -c '.[]' "$ROOT/openhim-config/hapi-channels.json" | while read -r channel; do
  name="$(jq -r .name <<<"$channel")"
  id="$(jq -r --arg n "$name" '.[] | select(.name == $n) | ._id' <<<"$existing")"
  if [[ -n "$id" ]]; then
    him -X PUT "$OPENHIM_API/channels/$id" -d "$channel" >/dev/null
    echo "updated $name"
  else
    him -X POST "$OPENHIM_API/channels" -d "$channel" >/dev/null
    echo "created $name"
  fi
done
