#!/usr/bin/env bash
# Onboard a hospital or laboratory: its HAPI Organization (written with the
# operators' onboarding client, since HAPI accepts no anonymous writes), then its
# Keycloak and OpenHIM clients (onboard-client.sh).
#   onboard-facility.sh <nhfr-code> "Facility Name" [hospital|laboratory]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NHFR="${1:-}" NAME="${2:-}" TYPE="${3:-hospital}"
usage="usage: $0 <nhfr-code> \"Facility Name\" [hospital|laboratory]"
[[ "$NHFR" == "--help" || "$NHFR" == "-h" ]] && { echo "$usage"; exit 0; }
[[ -n "$NHFR" && -n "$NAME" ]] || { echo "$usage" >&2; exit 1; }
[[ "$NHFR" =~ ^[0-9]+$ ]] || { echo "NHFR code must contain digits only." >&2; exit 1; }
[[ "$TYPE" == hospital || "$TYPE" == laboratory ]] || { echo "$usage" >&2; exit 1; }
[[ -f keys/onboarding.key.pem ]] || { echo "Onboard the operators' client first: scripts/onboard-client.sh onboarding \"Platform onboarding\" onboarding" >&2; exit 1; }

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
TOKEN="$("$ROOT/scripts/get-hospital-token.sh" onboarding)"
curl -kfsS -X PUT \
  "${HAPI_URL:-http://localhost:8081}/fhir/Organization?identifier=http://nhfr.digitalhealth.gov.np|$NHFR" \
  -H "Authorization: DPoP $TOKEN" -H "Content-Type: application/fhir+json" --data "$ORG" >/dev/null

exec "$ROOT/scripts/onboard-client.sh" "$NHFR" "$NAME" "$TYPE"
