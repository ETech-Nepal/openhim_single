#!/usr/bin/env bash
# Create or update one API client end to end: RSA keypair, DPoP-bound Keycloak
# private_key_jwt client with a sub mapper, its SMART scopes, and (for clients that
# call OpenHIM) the matching OpenHIM client.
#   onboard-client.sh <client-id> "Client Name" <type> [--allow-admin-role]
# Types and their scopes and OpenHIM role: keycloak/client-types.json
#   hospital, laboratory        facilities; client ID = NHFR code (use onboard-facility.sh)
#   identity-mediator           the identity mediator's own client (HAPI Patient writes)
#   onboarding                  operators' client for Organizations and Practitioners
#   admin-portal                the admin portal BFF (role np-admin-clients)
#   patient-portal              the patient portal BFF
#   patient-portal-mediator     the patient portal mediator's own client (HAPI reads)
# Run scripts/apply-realm-config.sh first: it creates the scopes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ID="${1:-}" NAME="${2:-}" TYPE="${3:-}" FLAG="${4:-}"
usage="usage: $0 <client-id> \"Client Name\" <type> [--allow-admin-role]"
[[ "$ID" == "--help" || "$ID" == "-h" ]] && { echo "$usage"; exit 0; }
[[ -n "$ID" && -n "$NAME" && -n "$TYPE" ]] || { echo "$usage" >&2; exit 1; }
[[ "$ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Client ID may contain only letters, digits, '.', '_' and '-'." >&2; exit 1; }
jq -e --arg t "$TYPE" 'has($t)' keycloak/client-types.json >/dev/null \
  || { echo "Unknown type '$TYPE'. Types: $(jq -r 'keys | join(", ")' keycloak/client-types.json)" >&2; exit 1; }
ROLE="$(jq -r --arg t "$TYPE" '.[$t].openhimRole // empty' keycloak/client-types.json)"
mapfile -t SCOPES < <(jq -r --arg t "$TYPE" '.[$t].scopes[]' keycloak/client-types.json)

# np-admin-clients can merge patient records. Only the admin portal holds it.
if [[ "$TYPE" == "admin-portal" && "$ID" != "admin-portal" && "$FLAG" != "--allow-admin-role" ]]; then
  echo "Refusing type admin-portal for '$ID': only admin-portal gets it. Pass --allow-admin-role to override." >&2
  exit 1
fi
OPENHIM_API="${OPENHIM_API:-https://localhost:8080}"

read -r -p "Keycloak realm admin username [hie-client-admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-hie-client-admin}"
read -r -s -p "Password for $ADMIN_USER: " ADMIN_PASSWORD
echo
if [[ -n "$ROLE" ]]; then
  # The mediators use a limited OpenHIM user; managing clients needs root.
  read -r -s -p "OpenHIM root@openhim.org password: " OPENHIM_PASSWORD
  echo
fi

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm openhie --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null
KC_ID="$(kc get clients -r openhie -q clientId="$ID" --fields id --format csv --noquotes)"

KEY_DIR="$ROOT/keys"
PRIVATE_KEY="$KEY_DIR/$ID.key.pem"
PUBLIC_KEY="$KEY_DIR/$ID.pub.pem"
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
KEY_ATTRS=(-s 'attributes."token.endpoint.auth.signing.alg"=RS256' -s 'attributes."use.jwks.url"=false' -s 'attributes."dpop.bound.access.tokens"=true')
if [[ -f "$PRIVATE_KEY" || -z "$KC_ID" ]]; then
  if [[ ! -f "$PRIVATE_KEY" ]]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" >/dev/null 2>&1
    openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
    chmod 600 "$PRIVATE_KEY"
  fi
  PUBLIC_DER_B64="$(openssl pkey -in "$PRIVATE_KEY" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n')"
  KEY_ATTRS+=(-s "attributes.\"jwt.credential.public.key\"=$PUBLIC_DER_B64")
else
  # Existing client whose private key was already handed over: keep its registered key.
  # A new key would lock the client out. To rotate, delete the client in Keycloak first.
  PRIVATE_KEY=""
fi
if [[ -z "$KC_ID" ]]; then
  kc create clients -r openhie -s "clientId=$ID" -s "name=$NAME" -s publicClient=false -s standardFlowEnabled=false -s serviceAccountsEnabled=true -s clientAuthenticatorType=client-jwt "${KEY_ATTRS[@]}" >/dev/null
  KC_ID="$(kc get clients -r openhie -q clientId="$ID" --fields id --format csv --noquotes)"
else
  kc update "clients/$KC_ID" -r openhie "${KEY_ATTRS[@]}" >/dev/null
fi

MAPPER_ID="$(kc get "clients/$KC_ID/protocol-mappers/models" -r openhie --fields id,name --format csv --noquotes | awk -F, '$2=="sub-as-client-id"||$2=="sub-as-nhfr"{print $1}')"
for m in $MAPPER_ID; do kc delete "clients/$KC_ID/protocol-mappers/models/$m" -r openhie; done
kc create "clients/$KC_ID/protocol-mappers/models" -r openhie -s name=sub-as-client-id -s protocol=openid-connect -s protocolMapper=oidc-hardcoded-claim-mapper -s 'config."claim.name"=sub' -s "config.\"claim.value\"=$ID" -s 'config."jsonType.label"=String' -s 'config."access.token.claim"=true' -s 'config."id.token.claim"=false' -s 'config."userinfo.token.claim"=false' >/dev/null

# SMART scopes: exactly the type's list, as default scopes so every token carries them.
ALL_SCOPES="$(kc get client-scopes -r openhie --fields id,name --format csv --noquotes)"
scope_id() { awk -F, -v n="$1" '$2==n{print $1}' <<<"$ALL_SCOPES"; }
for current in $(kc get "clients/$KC_ID/default-client-scopes" -r openhie --fields name --format csv --noquotes | grep '^system/' || true); do
  printf '%s\n' "${SCOPES[@]}" | grep -qxF "$current" || kc delete "clients/$KC_ID/default-client-scopes/$(scope_id "$current")" -r openhie
done
for scope in "${SCOPES[@]}"; do
  sid="$(scope_id "$scope")"
  [[ -n "$sid" ]] || { echo "Client scope $scope is missing; run scripts/apply-realm-config.sh first." >&2; exit 1; }
  kc update "clients/$KC_ID/default-client-scopes/$sid" -r openhie >/dev/null
done

# OpenHIM client, matched to the token sub. No password: it authenticates with its JWT.
if [[ -n "$ROLE" ]]; then
  him() { curl -kfsS -u "root@openhim.org:$OPENHIM_PASSWORD" -H 'Content-Type: application/json' "$@"; }
  HIM_ID="$(him "$OPENHIM_API/clients" | jq -r --arg id "$ID" '.[] | select(.clientID == $id) | ._id')"
  BODY="$(jq -n --arg id "$ID" --arg name "$NAME" --arg role "$ROLE" '{clientID: $id, name: $name, roles: [$role]}')"
  if [[ -z "$HIM_ID" ]]; then
    him -X POST "$OPENHIM_API/clients" -d "$BODY" >/dev/null
  else
    him -X PUT "$OPENHIM_API/clients/$HIM_ID" -d "$BODY" >/dev/null
  fi
fi

echo "Client '$NAME' ($ID) onboarded as $TYPE${ROLE:+ with OpenHIM role $ROLE}; scopes: ${SCOPES[*]:-none}."
if [[ -z "$PRIVATE_KEY" ]]; then
  echo "Kept the key already registered in Keycloak (no local private key)."
  exit 0
fi
echo "Private key: $PRIVATE_KEY"
case "$TYPE" in
  identity-mediator|onboarding|admin-portal|patient-portal|patient-portal-mediator) echo "Keep it on this host for the service that uses it." ;;
  *) echo "Transfer it securely to the client, then delete your local copy." ;;
esac
