#!/usr/bin/env bash
set -euo pipefail

CLIENT_ID="${1:-}"
if [[ "$CLIENT_ID" == "--help" || "$CLIENT_ID" == "-h" ]]; then
  echo "usage: $0 <client-id>"
  exit 0
fi
[[ "$CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "usage: $0 <client-id>" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_KEY="$ROOT/keys/$CLIENT_ID.key.pem"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8083}"
TOKEN_ENDPOINT="${KEYCLOAK_URL%/}/realms/openhie/protocol/openid-connect/token"

[[ -f "$PRIVATE_KEY" ]] || { echo "Missing private key: $PRIVATE_KEY" >&2; exit 1; }

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","jti":"%s","iat":%s,"exp":%s}' \
  "$CLIENT_ID" "$CLIENT_ID" "$TOKEN_ENDPOINT" "$(openssl rand -hex 16)" "$now" "$((now + 60))" | b64url)"
assertion="$header.$payload.$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$PRIVATE_KEY" | b64url)"

# Keycloak binds the token to this key (cnf.jkt). Each OpenHIM call then needs
# its own proof: scripts/dpop-proof.sh <key> <METHOD> <URL> <token>
response="$(curl -kfsS -X POST "$TOKEN_ENDPOINT" \
  -H "DPoP: $("$ROOT/scripts/dpop-proof.sh" "$PRIVATE_KEY" POST "$TOKEN_ENDPOINT")" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
  --data-urlencode "client_assertion=$assertion")"
token="$(jq -er '.access_token' <<<"$response")"
printf '%s\n' "$token"

