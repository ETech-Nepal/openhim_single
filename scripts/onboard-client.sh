#!/usr/bin/env bash
# Create or update one API client end to end: RSA keypair, DPoP-bound Keycloak
# private_key_jwt client with a sub mapper, and the matching OpenHIM client role.
#   onboard-client.sh <client-id> "Client Name" <openhim-role>
# Roles: np-fhir-clients (hospitals), np-admin-clients,
# patient-portal-clients.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ID="${1:-}" NAME="${2:-}" ROLE="${3:-}"
usage="usage: $0 <client-id> \"Client Name\" <openhim-role>"
[[ "$ID" == "--help" || "$ID" == "-h" ]] && { echo "$usage"; exit 0; }
[[ -n "$ID" && -n "$NAME" && -n "$ROLE" ]] || { echo "$usage" >&2; exit 1; }
[[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Client ID may contain only letters, digits, '.', '_' and '-'." >&2; exit 1; }

OPENHIM_PASSWORD="$(sed -n 's/^OPENHIM_PASSWORD=//p' env/mediator.env)"
[[ -n "$OPENHIM_PASSWORD" ]] || { echo "Set OPENHIM_PASSWORD in env/mediator.env first." >&2; exit 1; }
OPENHIM_API="${OPENHIM_API:-https://localhost:8080}"

read -r -p "Keycloak realm admin username [hie-client-admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-hie-client-admin}"
read -r -s -p "Password for $ADMIN_USER: " ADMIN_PASSWORD
echo

KEY_DIR="$ROOT/keys"
PRIVATE_KEY="$KEY_DIR/$ID.key.pem"
PUBLIC_KEY="$KEY_DIR/$ID.pub.pem"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
if [[ ! -f "$PRIVATE_KEY" ]]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" >/dev/null 2>&1
  openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
  chmod 600 "$PRIVATE_KEY"
fi
PUBLIC_DER_B64="$(openssl pkey -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm openhie --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null

KEY_ATTRS=(-s "attributes.\"jwt.credential.public.key\"=$PUBLIC_DER_B64" -s 'attributes."token.endpoint.auth.signing.alg"=RS256' -s 'attributes."use.jwks.url"=false' -s 'attributes."dpop.bound.access.tokens"=true')
KC_ID="$(kc get clients -r openhie -q clientId="$ID" --fields id --format csv --noquotes)"
if [[ -z "$KC_ID" ]]; then
  kc create clients -r openhie -s "clientId=$ID" -s "name=$NAME" -s publicClient=false -s standardFlowEnabled=false -s serviceAccountsEnabled=true -s clientAuthenticatorType=client-jwt "${KEY_ATTRS[@]}" >/dev/null
  KC_ID="$(kc get clients -r openhie -q clientId="$ID" --fields id --format csv --noquotes)"
else
  kc update "clients/$KC_ID" -r openhie "${KEY_ATTRS[@]}" >/dev/null
fi

MAPPER_ID="$(kc get "clients/$KC_ID/protocol-mappers/models" -r openhie --fields id,name --format csv --noquotes | awk -F, '$2=="sub-as-client-id"||$2=="sub-as-nhfr"{print $1}')"
for m in $MAPPER_ID; do kc delete "clients/$KC_ID/protocol-mappers/models/$m" -r openhie; done
kc create "clients/$KC_ID/protocol-mappers/models" -r openhie -s name=sub-as-client-id -s protocol=openid-connect -s protocolMapper=oidc-hardcoded-claim-mapper -s 'config."claim.name"=sub' -s "config.\"claim.value\"=$ID" -s 'config."jsonType.label"=String' -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null

# OpenHIM client, matched to the token sub. No password: it authenticates with its JWT.
him() { curl -kfsS -u "root@openhim.org:$OPENHIM_PASSWORD" -H 'Content-Type: application/json' "$@"; }
HIM_ID="$(him "$OPENHIM_API/clients" | jq -r --arg id "$ID" '.[] | select(.clientID == $id) | ._id')"
BODY="$(jq -n --arg id "$ID" --arg name "$NAME" --arg role "$ROLE" '{clientID: $id, name: $name, roles: [$role]}')"
if [[ -z "$HIM_ID" ]]; then
  him -X POST "$OPENHIM_API/clients" -d "$BODY" >/dev/null
else
  him -X PUT "$OPENHIM_API/clients/$HIM_ID" -d "$BODY" >/dev/null
fi

echo "Client '$NAME' ($ID) onboarded with OpenHIM role $ROLE and DPoP-bound tokens."
echo "Private key: $PRIVATE_KEY"
echo "Transfer it securely to the client, then delete your local copy."
