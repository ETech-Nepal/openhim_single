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

read -r -p "Keycloak realm admin username [hie-client-admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-hie-client-admin}"
read -r -s -p "Password for $ADMIN_USER: " ADMIN_PASSWORD
echo

KEY_DIR="$ROOT/keys"
PRIVATE_KEY="$KEY_DIR/$NHFR.key.pem"
PUBLIC_KEY="$KEY_DIR/$NHFR.pub.pem"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm openhie --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null

ORG="$(jq -n --arg nhfr "$NHFR" --arg name "$NAME" '{
  resourceType: "Organization",
  active: true,
  name: $name,
  identifier: [{
    use: "official",
    type: {coding: [{system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "FI"}]},
    system: "http://mohp.gov.np/fhir/NamingSystem/nhfr",
    value: $nhfr
  }]
}')"
curl -kfsS -X PUT \
  "http://localhost:8081/fhir/Organization?identifier=http://mohp.gov.np/fhir/NamingSystem/nhfr|$NHFR" \
  -H "Content-Type: application/fhir+json" --data "$ORG" >/dev/null

if [[ ! -f "$PRIVATE_KEY" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" >/dev/null 2>&1
  openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
  chmod 600 "$PRIVATE_KEY"
fi
PUBLIC_DER_B64="$(openssl pkey -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"
CLIENT_ID="$(kc get clients -r openhie -q clientId="$NHFR" --fields id --format csv --noquotes)"
if [[ -z "$CLIENT_ID" ]]; then
  kc create clients -r openhie -s "clientId=$NHFR" -s publicClient=false -s standardFlowEnabled=false -s serviceAccountsEnabled=true -s clientAuthenticatorType=client-jwt -s "attributes.\"jwt.credential.public.key\"=$PUBLIC_DER_B64" -s 'attributes."token.endpoint.auth.signing.alg"=RS256' -s 'attributes."use.jwks.url"=false' >/dev/null
  CLIENT_ID="$(kc get clients -r openhie -q clientId="$NHFR" --fields id --format csv --noquotes)"
else
  kc update "clients/$CLIENT_ID" -r openhie -s "attributes.\"jwt.credential.public.key\"=$PUBLIC_DER_B64" -s 'attributes."token.endpoint.auth.signing.alg"=RS256' -s 'attributes."use.jwks.url"=false' >/dev/null
fi

MAPPER_ID="$(kc get "clients/$CLIENT_ID/protocol-mappers/models" -r openhie --fields id,name --format csv --noquotes | awk -F, '$2=="sub-as-nhfr"{print $1}')"
[[ -z "$MAPPER_ID" ]] || kc delete "clients/$CLIENT_ID/protocol-mappers/models/$MAPPER_ID" -r openhie
kc create "clients/$CLIENT_ID/protocol-mappers/models" -r openhie -s name=sub-as-nhfr -s protocol=openid-connect -s protocolMapper=oidc-hardcoded-claim-mapper -s 'config."claim.name"=sub' -s "config.\"claim.value\"=$NHFR" -s 'config."jsonType.label"=String' -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null

docker compose exec -T -e HIP_CLIENT_SUB="$NHFR" -e HIP_CLIENT_NAME="$NAME" mediator node scripts/create-hip-client.js
echo "Hospital '$NAME' ($NHFR) onboarded."
echo "Private key: $PRIVATE_KEY"
echo "Transfer it securely to the hospital, then delete your local copy."
