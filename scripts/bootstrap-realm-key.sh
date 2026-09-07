#!/bin/sh
set -eu

realm_url=http://keycloak:8080/realms/openhie
output=/keys/realm-public.pem

while :; do
  key=$(wget -qO- "$realm_url" 2>/dev/null | sed -n 's/.*"public_key":"\([^"]*\)".*/\1/p')
  if [ -n "$key" ]; then
    {
      echo '-----BEGIN PUBLIC KEY-----'
      printf '%s\n' "$key" | fold -w 64
      echo '-----END PUBLIC KEY-----'
    } > "$output.tmp"
    mv "$output.tmp" "$output"
    exit 0
  fi
  sleep 2
done
