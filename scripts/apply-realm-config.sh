#!/usr/bin/env bash
# Brings the running openhie realm to the configuration this repository expects.
# Idempotent; run it after the first start and after every upgrade (--import-realm
# never changes a realm that already exists):
#   * the DPoP client policy from keycloak/realm-export.json;
#   * one client scope per SMART scope named in keycloak/client-types.json
#     (onboard-client.sh attaches them to clients by type);
#   * admin portal sign-in: brute-force protection, the password + OTP flow
#     admin-portal-mfa, the web client admin-portal-web and its roles;
#   * realm-management/manage-clients for admin-portal-provisioner, once that client is
#     onboarded (run this script again after onboarding it);
#   * removes the old demo client and user.
# The web client's URLs come from ADMIN_PORTAL_API_URL and ADMIN_PORTAL_UI_URL. Without
# them an existing client keeps its URLs; a new one gets the localhost defaults.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
read -r -p "Keycloak bootstrap admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"
read -r -s -p "Keycloak bootstrap admin password: " ADMIN_PASSWORD
echo

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null
jq '.clientProfiles' keycloak/realm-export.json | kc update realms/openhie/client-policies/profiles -f -
jq '.clientPolicies' keycloak/realm-export.json | kc update realms/openhie/client-policies/policies -f -

existing="$(kc get client-scopes -r openhie --fields name --format csv --noquotes)"
for scope in $(jq -r '[.[].scopes[]] | unique[]' keycloak/client-types.json); do
  grep -qxF "$scope" <<<"$existing" && continue
  kc create client-scopes -r openhie -s "name=$scope" -s protocol=openid-connect \
    -s 'description=SMART v2 backend-service scope' \
    -s 'attributes."include.in.token.scope"=true' -s 'attributes."display.on.consent.screen"=false' >/dev/null
  echo "created client scope $scope"
done

# --- Admin portal sign-in ---
client_uuid() { kc get clients -r openhie -q clientId="$1" --fields id --format csv --noquotes; }
kc update realms/openhie -s bruteForceProtected=true -s failureFactor=5

# Password then OTP, both required, and no cookie step: an existing single sign-on session
# cannot skip the second factor.
FLOW=admin-portal-mfa
flow_id() { kc get authentication/flows -r openhie | jq -r --arg a "$FLOW" '.[] | select(.alias == $a) | .id'; }
if [[ -z "$(flow_id)" ]]; then
  kc create authentication/flows -r openhie -s "alias=$FLOW" -s providerId=basic-flow -s topLevel=true -s builtIn=false >/dev/null
  echo "created flow $FLOW"
fi
executions() { kc get "authentication/flows/$FLOW/executions" -r openhie; }
for provider in auth-username-password-form auth-otp-form; do
  executions | jq -e --arg p "$provider" 'any(.[]; .providerId == $p)' >/dev/null \
    || kc create "authentication/flows/$FLOW/executions/execution" -r openhie -s "provider=$provider" >/dev/null
done
for id in $(executions | jq -r '.[] | select(.requirement != "REQUIRED") | .id'); do
  jq -n --arg id "$id" '{id: $id, requirement: "REQUIRED"}' \
    | kc update "authentication/flows/$FLOW/executions" -r openhie -f -
done

WEB_ID="$(client_uuid admin-portal-web)"
API_URL="${ADMIN_PORTAL_API_URL:-}"
UI_URL="${ADMIN_PORTAL_UI_URL:-}"
if [[ -z "$WEB_ID" ]]; then
  API_URL="${API_URL:-http://localhost:4200}"
  UI_URL="${UI_URL:-http://localhost:8091}"
fi
WEB_SETTINGS=(-s publicClient=false -s standardFlowEnabled=true -s directAccessGrantsEnabled=false
  -s serviceAccountsEnabled=false -s implicitFlowEnabled=false
  -s 'attributes."pkce.code.challenge.method"=S256' -s 'attributes."dpop.bound.access.tokens"=true'
  -s "authenticationFlowBindingOverrides.browser=$(flow_id)")
[[ -z "$API_URL" ]] || WEB_SETTINGS+=(-s "redirectUris=[\"${API_URL%/}/auth/callback\"]")
[[ -z "$UI_URL" ]] || WEB_SETTINGS+=(-s "attributes.\"post.logout.redirect.uris\"=${UI_URL%/}")
if [[ -z "$WEB_ID" ]]; then
  kc create clients -r openhie -s clientId=admin-portal-web -s "name=Admin portal sign-in" "${WEB_SETTINGS[@]}" >/dev/null
  WEB_ID="$(client_uuid admin-portal-web)"
  echo "created client admin-portal-web"
else
  kc update "clients/$WEB_ID" -r openhie "${WEB_SETTINGS[@]}"
fi
ROLES="$(kc get "clients/$WEB_ID/roles" -r openhie --fields name --format csv --noquotes)"
for role in platform-admin duplicate-reviewer; do
  grep -qxF "$role" <<<"$ROLES" || kc create "clients/$WEB_ID/roles" -r openhie -s "name=$role" >/dev/null
done

if [[ -n "$(client_uuid admin-portal-provisioner)" ]]; then
  kc add-roles -r openhie --uusername service-account-admin-portal-provisioner --cclientid realm-management --rolename manage-clients
  echo "admin-portal-provisioner has realm-management/manage-clients"
else
  echo "admin-portal-provisioner is not onboarded yet: onboard it, then run this script again."
fi
echo "admin-portal-web client secret (WEB_CLIENT_SECRET in admin_portal/backend/.env):"
kc get "clients/$WEB_ID/client-secret" -r openhie | jq -r .value

for id in $(kc get clients -r openhie -q clientId=demo-client --fields id --format csv --noquotes); do
  kc delete "clients/$id" -r openhie
done
for id in $(kc get users -r openhie -q username=demo -q exact=true --fields id --format csv --noquotes); do
  kc delete "users/$id" -r openhie
done
echo "Realm openhie: DPoP policy, SMART client scopes and admin portal sign-in in place; demo client and user removed."
