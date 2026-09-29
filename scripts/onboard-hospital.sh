#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NHFR="${1:-}"
NAME="${2:-}"
if [[ "$NHFR" == "--help" || "$NHFR" == "-h" ]]; then
  echo "usage: $0 <nhfr-code> \"Hospital Name\""
  exit 0
fi
if [[ -z "$NHFR" || -z "$NAME" ]]; then
  echo "usage: $0 <nhfr-code> \"Hospital Name\"" >&2
  exit 1
fi
[[ "$NHFR" =~ ^[0-9]+$ ]] || { echo "NHFR code must contain digits only." >&2; exit 1; }

ORG="$(jq -n --arg nhfr "$NHFR" --arg name "$NAME" '{
  resourceType: "Organization",
  meta: {profile: ["http://fhir.digitalhealth.gov.np/core/StructureDefinition/np-core-organization"]},
  active: true,
  name: $name,
  identifier: [{
    use: "official",
    type: {coding: [{system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "FI"}]},
    system: "http://nhfr.digitalhealth.gov.np",
    value: $nhfr
  }]
}')"
curl -kfsS -X PUT \
  "http://localhost:8081/fhir/Organization?identifier=http://nhfr.digitalhealth.gov.np|$NHFR" \
  -H "Content-Type: application/fhir+json" --data "$ORG" >/dev/null

exec "$ROOT/scripts/onboard-client.sh" "$NHFR" "$NAME" np-fhir-clients
