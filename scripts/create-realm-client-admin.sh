#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
USERNAME="${1:-hie-client-admin}"
if [[ "$USERNAME" == "--help" || "$USERNAME" == "-h" ]]; then
  echo "usage: $0 [username]"
  exit 0
fi

read -r -p "Keycloak bootstrap admin username [admin]: " BOOTSTRAP_USER
BOOTSTRAP_USER="${BOOTSTRAP_USER:-admin}"
read -r -s -p "Keycloak bootstrap admin password: " BOOTSTRAP_PASSWORD
echo
read -r -s -p "Password for $USERNAME: " USER_PASSWORD
echo
read -r -s -p "Confirm password: " CONFIRM_PASSWORD
echo
[[ "$USER_PASSWORD" == "$CONFIRM_PASSWORD" ]] || { echo "Passwords do not match." >&2; exit 1; }

kc() { docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

kc config credentials --server http://localhost:8080 --realm master --user "$BOOTSTRAP_USER" --password "$BOOTSTRAP_PASSWORD" >/dev/null
USER_ID="$(kc get users -r openhie -q username="$USERNAME" --fields id --format csv --noquotes)"
if [[ -z "$USER_ID" ]]; then
  kc create users -r openhie -s "username=$USERNAME" -s enabled=true -s "email=$USERNAME@hie.local" -s emailVerified=true -s firstName=HIE -s lastName=ClientAdmin >/dev/null
fi
kc set-password -r openhie --username "$USERNAME" --new-password "$USER_PASSWORD"
kc add-roles -r openhie --uusername "$USERNAME" --cclientid realm-management --rolename manage-clients
echo "Created or updated '$USERNAME' with realm-management/manage-clients in realm openhie."

