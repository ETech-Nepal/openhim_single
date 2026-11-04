#!/bin/sh
# Creates the keycloak and identity roles and databases. Idempotent: it runs
# automatically on a new hapi-db volume, and by hand on an existing one:
#   docker compose stop admin-mediator
#   docker compose exec hapi-db sh /docker-entrypoint-initdb.d/10-roles.sh
# Renaming admin_review fails while something is connected to it.
set -eu
: "${POSTGRES_USER:?}" "${KEYCLOAK_DB_PASSWORD:?set in .env}" "${IDENTITY_DB_PASSWORD:?set in .env}"

psql() { command psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$@"; }

psql -d postgres -v kc_pw="$KEYCLOAK_DB_PASSWORD" -v id_pw="$IDENTITY_DB_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak') \gexec
SELECT 'CREATE ROLE identity LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'identity') \gexec
ALTER ROLE keycloak PASSWORD :'kc_pw';
ALTER ROLE identity PASSWORD :'id_pw';

SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak') \gexec
-- Existing stacks: the review queue database becomes the identity database.
SELECT 'ALTER DATABASE admin_review RENAME TO identity'
  WHERE EXISTS (SELECT FROM pg_database WHERE datname = 'admin_review')
    AND NOT EXISTS (SELECT FROM pg_database WHERE datname = 'identity') \gexec
SELECT 'CREATE DATABASE identity OWNER identity' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'identity') \gexec
ALTER DATABASE keycloak OWNER TO keycloak;
ALTER DATABASE identity OWNER TO identity;

-- Each role reaches only its own database.
REVOKE CONNECT ON DATABASE hapi, keycloak, identity FROM PUBLIC;
GRANT CONNECT ON DATABASE keycloak TO keycloak;
GRANT CONNECT ON DATABASE identity TO identity;
SQL

# Tables created earlier by the superuser (review_tasks) move to the identity role.
psql -d identity <<'SQL'
ALTER SCHEMA public OWNER TO identity;
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO identity', t.tablename);
  END LOOP;
END $$;
SQL
