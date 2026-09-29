#!/usr/bin/env bash
# Print a DPoP proof (RFC 9449) signed with an RSA private key.
#   dpop-proof.sh <key.pem> <METHOD> <URL> [access_token]
# Pass the access token for OpenHIM requests (adds ath). Omit it for the Keycloak
# token endpoint. Every request needs a fresh proof: OpenHIM rejects a reused jti.
set -euo pipefail

KEY="${1:-}" HTM="${2:-}" HTU="${3:-}" TOKEN="${4:-}"
if [[ -z "$KEY" || -z "$HTM" || -z "$HTU" ]]; then
  echo "usage: $0 <key.pem> <METHOD> <URL> [access_token]" >&2
  exit 1
fi
[[ -f "$KEY" ]] || { echo "Missing private key: $KEY" >&2; exit 1; }

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
hex2b64url() {
  local hex="$1"
  (( ${#hex} % 2 )) && hex="0$hex"
  printf '%b' "$(sed 's/../\\x&/g' <<<"$hex")" | b64url
}

text="$(openssl pkey -in "$KEY" -pubout 2>/dev/null | openssl rsa -pubin -noout -text 2>/dev/null)"
n_hex="$(openssl pkey -in "$KEY" -pubout 2>/dev/null | openssl rsa -pubin -noout -modulus 2>/dev/null | cut -d= -f2)"
e_dec="$(sed -n 's/^Exponent: \([0-9]*\).*/\1/p' <<<"$text")"
n="$(hex2b64url "$n_hex")"
e="$(hex2b64url "$(printf '%x' "$e_dec")")"

header="$(printf '{"typ":"dpop+jwt","alg":"RS256","jwk":{"kty":"RSA","n":"%s","e":"%s"}}' "$n" "$e" | b64url)"
ath=""
[[ -z "$TOKEN" ]] || ath="$(printf ',"ath":"%s"' "$(printf '%s' "$TOKEN" | openssl dgst -sha256 -binary | b64url)")"
payload="$(printf '{"htm":"%s","htu":"%s","jti":"%s","iat":%s%s}' \
  "$HTM" "${HTU%%\?*}" "$(openssl rand -hex 16)" "$(date +%s)" "$ath" | b64url)"
printf '%s.%s.%s' "$header" "$payload" "$(printf '%s' "$header.$payload" | openssl dgst -sha256 -sign "$KEY" | b64url)"
