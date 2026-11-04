#!/usr/bin/env bash
# Brings the running openhie realm to the configuration this repository expects.
# Idempotent; run it after the first start and after every upgrade (--import-realm
# never changes a realm that already exists):
#   * the DPoP client policy from keycloak/realm-export.json;
#   * one client scope per SMART scope named in keycloak/client-types.json
#     (onboard-client.sh attaches them to clients by type);
#   * removes the old demo client and user.
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

for id in $(kc get clients -r openhie -q clientId=demo-client --fields id --format csv --noquotes); do
  kc delete "clients/$id" -r openhie
done
for id in $(kc get users -r openhie -q username=demo -q exact=true --fields id --format csv --noquotes); do
  kc delete "users/$id" -r openhie
done
echo "Realm openhie: DPoP policy and SMART client scopes in place; demo client and user removed."
