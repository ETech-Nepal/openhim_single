# OpenHIE single-stack deployment

This folder runs OpenHIM, Keycloak, HAPI FHIR (with the platform's access rules built in), MongoDB, PostgreSQL, the identity mediator and the transform mediator. Every API client authenticates with a DPoP-bound Keycloak token (RFC 9449). It does not need the application source tree.

| Service | Image | Does |
| --- | --- | --- |
| fhir | `openhie-hapi` | HAPI FHIR 8.12 with the access-rules plugin: verifies the token on every request, checks SMART scopes, stamps and checks the owning facility, limits searches, accepts Patient writes only from the identity mediator |
| identity-mediator | `openhie-identity-mediator` | Every Patient write: JeMPI match, Health ID issuing (`health_ids` table), HAPI Patient upsert. Duplicate review and merge for the admin portal |
| transform-mediator | `fhir-transform-mediator` | CDRS rows (`/transform/cdrs`) and FHIR Bundles posted to `/fhir`: validation, Patients to the identity mediator, the rest to HAPI with the client's token |
| openhim-core, openhim-console | | Authentication (token + DPoP), routing, transaction log |
| keycloak | | Clients, SMART scopes, DPoP-bound tokens; data in PostgreSQL |
| hapi-db | | PostgreSQL: databases `hapi`, `keycloak`, `identity` |

JeMPI runs on its own host and is reached over WireGuard.

## Requirements

Install Docker Engine with the Docker Compose plugin. Install curl, jq, and openssl before onboarding clients.

```bash
sudo apt-get update
sudo apt-get install -y curl jq openssl
docker compose version
```

## Configure the stack

Create the runtime environment files once.

```bash
git clone https://github.com/ETech-Nepal/openhim_single.git openhie_stack
cd openhie_stack
cp .env.example .env
for file in env/*.env.example; do cp "$file" "${file%.example}"; done
```

Edit every file before starting.

| File | Required values |
| --- | --- |
| .env | Set the five secrets (HAPI_DB_PASSWORD, KEYCLOAK_DB_PASSWORD, KEYCLOAK_ADMIN_PASSWORD, IDENTITY_DB_PASSWORD, OPENHIM_SESSION_KEY); generate each with `openssl rand -base64 32`. Set OPENHIE_IMAGE_TAG to the openhie commit SHA to deploy. The stack refuses to start without them. For a domain deployment, set DOMAIN, KEYCLOAK_PUBLIC_URL, and KEYCLOAK_ISSUER to public HTTPS URLs, and PUBLIC_BASE_URL to the URL clients call OpenHIM on (https://openhim.<DOMAIN>). DPoP proofs must name that exact URL. |
| env/identity-mediator.env | OPENHIM_PASSWORD (the mediators@openhim.local password, see [First start](#first-start)). Keep JEMPI_BASE_URL on the WireGuard address. |
| env/transform-mediator.env | OPENHIM_PASSWORD. |
| env/patient-portal-mediator.env | OPENHIM_PASSWORD, and a strong PORTAL_PATIENT_SHARED_SECRET (the patient portal BFF's session secret). |

The .env and env/\*.env files contain secrets and stay ignored by Git. The transform mediator's apps, channels and mappings are in `mediator-config/transform/`; edit them and recreate the service, no image rebuild needed.

## First start

The order matters: the identity mediator needs its Keycloak client key before it starts, and HAPI accepts no write without a token, so the operators' onboarding client comes before any facility.

1. Start the platform services:

   ```bash
   docker compose pull
   docker compose config --quiet
   docker compose up -d hapi-db mongo-db keycloak openhim-core openhim-console fhir
   ```

2. Create the Keycloak client administrator and bring the realm to the expected configuration (DPoP policy, one client scope per SMART scope, demo client removed). Both prompt for the Keycloak bootstrap admin (`admin` / KEYCLOAK_ADMIN_PASSWORD):

   ```bash
   ./scripts/create-realm-client-admin.sh
   ./scripts/apply-realm-config.sh
   ```

   See [Create a Keycloak client administrator](#create-a-keycloak-client-administrator) for the manual way.

3. OpenHIM login and the mediators' user:

   1. Open the OpenHIM Console and sign in as root@openhim.org with the initial password openhim-password.
   2. Change the root password in the Console. Change it there, not with a plain `PUT /users` API call: OpenHIM's token scheme uses a separate password hash that only the Console keeps in step. Keep the root password with the operators; nothing in env/ uses it.
   3. Create the role the mediators log in with (register, heartbeat, create and update their own channels, nothing else): `./scripts/create-mediator-role.sh`
   4. In the Console, go to **Users** → **+ User**: email `mediators@openhim.local`, first name Mediators, surname Service, role **mediator-registration**. Set a strong password and put it in OPENHIM_PASSWORD in env/identity-mediator.env, env/transform-mediator.env and env/patient-portal-mediator.env.

4. Onboard the platform's own clients. Each run prompts for the hie-client-admin password and, where an OpenHIM client is created, the OpenHIM root password. Keys land in keys/, which Git ignores:

   ```bash
   ./scripts/onboard-client.sh onboarding "Platform onboarding" onboarding
   ./scripts/onboard-client.sh identity-mediator "Identity mediator" identity-mediator
   ./scripts/onboard-client.sh admin-portal "Patient Admin Portal" admin-portal
   ./scripts/onboard-client.sh patient-portal-mediator "Patient portal mediator" patient-portal-mediator
   ./scripts/onboard-client.sh patient-portal "Patient Portal BFF" patient-portal
   ```

   `onboarding` is the operators' client for writing Organizations and Practitioners to HAPI. `identity-mediator` is the only client HAPI accepts Patient writes from. `patient-portal-mediator` reads HAPI for the patient portal (read-only scopes; the only client allowed to find a Patient by phone, for the OTP login). Compose mounts both mediator keys into their containers. The `admin-portal` key goes to the admin portal BFF (`admin_portal/docker-compose.yml` mounts it from `keys/`), the `patient-portal` key to the patient portal BFF.

5. Register the channels that route `/fhir` reads and single-resource writes straight to HAPI (`openhim-config/hapi-channels.json`; prompts for the OpenHIM root password; rerun after every change to that file):

   ```bash
   ./scripts/apply-hapi-channels.sh
   ```

6. Start the mediators. They register their own channels with OpenHIM.

   ```bash
   docker compose up -d
   docker compose ps
   ```

7. Onboard the facilities ([below](#onboard-a-hospital-or-laboratory)).

An `Invalid env config` error with an empty OPENHIM_PASSWORD means a mediator env file still has the placeholder value.

### Ports and checks

| Service | URL |
| --- | --- |
| OpenHIM Console | http://localhost:9000 |
| OpenHIM Core API | https://localhost:8080 |
| OpenHIM transactions (clients) | https://localhost:5000 |
| HAPI FHIR | http://localhost:8081/fhir |
| Keycloak | http://localhost:8083 |

These ports listen on 127.0.0.1 only. From another machine, use an SSH tunnel, for example `ssh -L 9000:127.0.0.1:9000 -L 8080:127.0.0.1:8080 -L 8083:127.0.0.1:8083 <host>`. In the vps profile, Caddy publishes the Console and the API on their subdomains and Keycloak without its admin console (`/admin` and the master realm answer 404). Client traffic uses the OpenHIM transaction port (5000, or `openhim.<DOMAIN>` through Caddy).

```bash
curl -kfsS https://localhost:8080/heartbeat
curl -fsS http://localhost:8081/fhir/metadata   # the only HAPI route open without a token
```

OpenHIM verifies client JWTs against the realm JWKS (KEYCLOAK_JWKS_URI), fetched live and cached; the URL must be reachable from inside the openhim-core container. A token that carries `cnf.jkt` is accepted only with a matching `DPoP` proof whose `htu` is `PUBLIC_BASE_URL` plus the request path; each proof is single-use. OpenHIM Core runs with `NODE_ENV=production` and loads `openhim-config/production.json`, which turns client Basic authentication off.

HAPI verifies the same token again (NP_AUTH_ISSUER, NP_AUTH_JWKS_URI in docker-compose.yml) and refuses any request without one, so a request that reaches port 8081 without passing OpenHIM still fails.

## Channels

In the OpenHIM Console, confirm these channels. Lower priority numbers are matched first.

| Channel | Path and methods | Priority | Roles | Registered by |
| --- | --- | --- | --- | --- |
| NP Patient Identity | `/fhir/Patient[/<id>]` POST, PUT | 1 | hospital, laboratory | identity mediator |
| FHIR Middleware: fhir-bundle-v1 | `/fhir` POST (Bundle) | 1 | hospital, laboratory | transform mediator |
| FHIR Middleware: cdrs-v1 | `/transform/cdrs` POST | 1 | hospital | transform mediator |
| NP Patient Admin Review | `/admin/*` GET, POST | 1 | np-admin-clients | identity mediator |
| NP FHIR write | `/fhir/<Type>[/<id>]` POST, PUT | 2 | hospital, laboratory | apply-hapi-channels.sh |
| NP FHIR read | `/fhir/...` GET, HEAD | 2 | hospital, laboratory | apply-hapi-channels.sh |

No channel allows DELETE. Every channel forwards the client's token: the OpenHIM role only picks the route, and the token's SMART scopes (`keycloak/client-types.json`) decide what the client may read and write. Organizations and Practitioners are read-only for facilities; the onboarding client writes them to HAPI directly.

## Onboard a hospital or laboratory

Each facility needs:

1. A HAPI Organization whose NHFR identifier is the facility's NHFR code.
2. A Keycloak private_key_jwt client with that code as client ID, DPoP-bound tokens, a mapper that sets `sub` to the code, and the SMART scopes of its type.
3. An OpenHIM client with the same code and role `hospital` or `laboratory`.

```bash
./scripts/onboard-facility.sh 3130400221 "Bharatpur Hospital" hospital
./scripts/onboard-facility.sh 3130400299 "Bharatpur Laboratory" laboratory
```

The script writes the Organization with the onboarding client's token, then runs `onboard-client.sh`, which creates the keypair, the Keycloak client with its mapper and scopes, and the OpenHIM client. Transfer keys/<code>.key.pem to the facility through a secure channel and delete your local copy.

Rerunning it for an existing facility updates its scopes and OpenHIM role and keeps its registered key when there is no local private key. To issue a new key, delete the client in Keycloak first.

### Manual onboarding

Use a real NHFR code in place of 3130400221.

1. **Organization.** HAPI needs a token for every write, so use the onboarding client:

   ```bash
   TOKEN="$(./scripts/get-hospital-token.sh onboarding)"
   curl -fsS -X PUT 'http://localhost:8081/fhir/Organization?identifier=http://nhfr.digitalhealth.gov.np|3130400221' \
     -H "Authorization: DPoP $TOKEN" -H 'Content-Type: application/fhir+json' -d '{
       "resourceType": "Organization",
       "meta": {"profile": ["http://fhir.digitalhealth.gov.np/core/StructureDefinition/np-core-organization"]},
       "active": true,
       "name": "Bharatpur Hospital",
       "identifier": [{"use": "official",
         "type": {"coding": [{"system": "http://terminology.hl7.org/CodeSystem/v2-0203", "code": "FI"}]},
         "system": "http://nhfr.digitalhealth.gov.np", "value": "3130400221"}]
     }'
   ```

   The conditional PUT keeps exactly one Organization for each NHFR code.

2. **Keypair.**

   ```bash
   openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out keys/3130400221.key.pem
   openssl pkey -in keys/3130400221.key.pem -pubout -out keys/3130400221.pub.pem
   chmod 600 keys/3130400221.key.pem
   ```

3. **Keycloak client.** Log in as hie-client-admin, realm **openhie**.
   1. **Clients** → **Create client**: OpenID Connect, Client ID 3130400221. Enable **Client authentication** and **Service accounts roles**, disable **Standard flow**, save.
   2. **Credentials**: client authenticator **Signed JWT**, algorithm RS256.
   3. **Keys**: disable **Use JWKS URL**, import keys/3130400221.pub.pem.
   4. **Advanced** → **Advanced settings**: turn on **OAuth 2.0 DPoP Bound Access Tokens Enabled**, save.
   5. **Client scopes** → **Add client scope**: add every scope listed for the type in `keycloak/client-types.json` as **Default**.
   6. **Client scopes** → **3130400221-dedicated** → **Mappers** → **Configure a new mapper** → **Hardcoded claim**: name `sub-as-client-id`, token claim name `sub`, value `3130400221`, JSON type String, access token on, ID token and userinfo off.

4. **OpenHIM client.** In the Console as root: **Clients** → **+ Client**, Client ID 3130400221, name Bharatpur Hospital, role `hospital` (or `laboratory`). Leave Basic-auth credentials empty.

## Admin portal

The admin portal BFF uses the `admin-portal` client (onboarded in [First start](#first-start)) with role np-admin-clients. A facility token is refused on `/admin`, and the admin token is refused on `/fhir`. `onboard-client.sh` refuses the admin-portal type for any client ID other than admin-portal unless `--allow-admin-role` is passed, because that role can merge patient records. Merge and dismiss require an `X-Admin-User` header, which the BFF sets from its own login session.

## Create a Keycloak client administrator

Use this account to manage clients in realm openhie. It gets realm-management/manage-clients instead of full realm administration. `./scripts/create-realm-client-admin.sh` does this; it prompts for both passwords and keeps them out of shell history.

1. In Keycloak, select realm **openhie**.
2. Go to **Users** → **Add user**. Create hie-client-admin and enable it.
3. Open **Credentials** and set a permanent password.
4. Open **Role mapping** → **Assign role**.
5. Choose **Filter by clients**, select **realm-management**, check **manage-clients**, and assign it.
6. Keycloak may also show create-client. Keep it assigned.

If you only see account/manage-account roles, click **Assign role** first. The realm-management roles are in the client-role filter. Confirm the active realm is openhie, not master.

## NP Core IG 1.0.0

HAPI loads `hapi-config/np.core-1.0.0.tgz` (canonical `http://fhir.digitalhealth.gov.np/core`)
and validates every write against the profiles a resource declares. Two settings in
`hapi-config/application.yaml` are required, or every Nepal address is rejected:
`installMode: STORE_AND_INSTALL` and the Lucene index on the `hapi-lucene-data`
volume. Check after the first start (the IG loads in the background; allow a few minutes), with any facility or onboarding token:

```bash
TOKEN="$(./scripts/get-hospital-token.sh onboarding)"
curl -s -H "Authorization: DPoP $TOKEN" 'http://localhost:8081/fhir/ValueSet/$expand?url=http://fhir.digitalhealth.gov.np/core/ValueSet/nepal-province-vs' | jq .expansion.total   # 7
```

A conditional reference whose identifier system has no path, such as `Patient?identifier=http://donidcr.gov.np|123`, must be URL-encoded (`http%3A%2F%2Fdonidcr.gov.np%7C123`). HAPI 8.12's validator fails on the unencoded form; HAPI answers 400 with that advice.

## Keycloak realm

Keycloak runs in production mode (`start`) and stores its data in the `keycloak` database on hapi-db. It imports the openhie realm on first start; `--import-realm` never changes a realm that already exists, so run `./scripts/apply-realm-config.sh` after every upgrade. OpenHIM and HAPI read signing keys from the realm JWKS endpoint.

The realm has a client policy that makes DPoP mandatory for every confidential client: a token request without a DPoP proof is refused, and the setting cannot be switched off per client. The bootstrap admin password is KEYCLOAK_ADMIN_PASSWORD from .env.

## JeMPI over WireGuard

JeMPI carries patient demographics and has no authentication of its own, so it is reached only through a WireGuard tunnel between this host and the JeMPI host. Run these on the hosts yourself.

On both hosts:

```bash
sudo apt-get install -y wireguard
wg genkey | sudo tee /etc/wireguard/private.key | wg pubkey | sudo tee /etc/wireguard/public.key
sudo chmod 600 /etc/wireguard/private.key
```

Platform host, `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.60.0.1/30
PrivateKey = <platform private key>

[Peer]
PublicKey = <JeMPI public key>
Endpoint = <JeMPI public IP>:51820
AllowedIPs = 10.60.0.2/32
PersistentKeepalive = 25
```

JeMPI host, `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.60.0.2/30
ListenPort = 51820
PrivateKey = <JeMPI private key>

[Peer]
PublicKey = <platform public key>
AllowedIPs = 10.60.0.1/32
```

Then on both: `sudo systemctl enable --now wg-quick@wg0`. On the JeMPI host, accept the JeMPI API only through the tunnel from the platform (UDP 51820 must be open to the platform's public IP):

```bash
sudo iptables -I INPUT -p tcp --dport 50000 -j DROP
sudo iptables -I INPUT -i wg0 -s 10.60.0.1 -p tcp --dport 50000 -j ACCEPT
```

If JeMPI publishes port 50000 through Docker, add the same two rules to the `DOCKER-USER` chain instead, because Docker's published ports bypass `INPUT`. Make the rules persistent (`iptables-persistent`). Check from the platform:

```bash
docker compose exec identity-mediator wget -qO- http://10.60.0.2:50000/JeMPI/countRecords
```

## Upgrading an existing stack

Older stacks ran three mediators (`mediator`, `fhir-intake-mediator`, `admin-mediator`), Keycloak in dev mode with its data in the `keycloak-data` volume, the review queue in the `admin_review` database, and hospitals with OpenHIM role np-fhir-clients. The `/ingest` route is gone: CDRS rows go to `/transform/cdrs`.

1. **Before pulling the new files**, back up, export the realm and stop the old mediators:

   ```bash
   docker compose exec hapi-db pg_dumpall -U admin > backup.sql
   docker compose exec keycloak /opt/keycloak/bin/kc.sh export --dir /tmp/kc-export --realm openhie --users realm_file
   docker compose cp keycloak:/tmp/kc-export/openhie-realm.json ./openhie-realm-backup.json
   docker compose stop mediator fhir-intake-mediator admin-mediator keycloak
   ```

   Also back up the `keycloak-data` volume.

2. Update the files. Add the five secrets and OPENHIE_IMAGE_TAG to .env, create env/identity-mediator.env and env/transform-mediator.env from their examples, add the KEYCLOAK_TOKEN_URL, PORTAL_CLIENT_ID and PORTAL_CLIENT_KEY_PATH lines from env/patient-portal-mediator.env.example to env/patient-portal-mediator.env, and delete env/mediator.env, env/fhir-intake-mediator.env and env/admin-mediator.env. Set the database password the old compose file hard-coded (`admin`) to HAPI_DB_PASSWORD:

   ```bash
   docker compose up -d --remove-orphans hapi-db
   docker compose exec hapi-db psql -U admin -d postgres -c "ALTER ROLE admin PASSWORD '<HAPI_DB_PASSWORD>'"
   ```

3. Create the keycloak and identity roles and databases (this renames `admin_review` to `identity`):

   ```bash
   docker compose exec hapi-db sh /docker-entrypoint-initdb.d/10-roles.sh
   ```

4. Start Keycloak on PostgreSQL with the exported realm (it carries the hospital clients and their keys), then apply the realm configuration:

   ```bash
   cp openhie-realm-backup.json keycloak/realm-export.json
   docker compose up -d keycloak
   git checkout keycloak/realm-export.json
   ./scripts/apply-realm-config.sh
   ```

5. Start OpenHIM and HAPI (`docker compose up -d mongo-db openhim-core openhim-console fhir`), then follow [First start](#first-start) steps 3 to 6: mediator role and user, the platform clients, the HAPI channels, then the mediators. Point the admin portal BFF at the `admin-portal` key and update the hospital adapters ([Hospital adapter](#hospital-adapter)).

6. In the OpenHIM Console, delete the old channels **NP FHIR Orchestrator** and **NP FHIR Intake** and the old mediators' entries under **Mediators**. Left in place, the old `/fhir` channel would still match requests.

7. Move every existing hospital to the new role and scopes. Without a local private key, the hospital's registered key is kept:

   ```bash
   ./scripts/onboard-client.sh 3130400221 "Bharatpur Hospital" hospital
   ```

8. Load the Health IDs already in HAPI into the register, then rewrite MRNs stored on the shared `hospital-mrn` system to each hospital's own system (dry run first):

   ```bash
   docker compose exec identity-mediator node dist/scripts/backfill-health-ids.js
   docker compose exec identity-mediator node dist/scripts/migrate-mrn-systems.js
   docker compose exec identity-mediator node dist/scripts/migrate-mrn-systems.js --apply
   ```

9. Run the [smoke test](#smoke-test), then remove the old volume: `docker volume rm openhim_keycloak-data`.

Backups must include the `keycloak` and `identity` databases (`pg_dumpall` covers both).

## Smoke test

Finish onboarding first. `get-hospital-token.sh` signs the client assertion with the facility's private key and sends a DPoP proof, so Keycloak binds the token to that key. Every OpenHIM call then needs a fresh proof from `dpop-proof.sh` with the same key, method, and URL.

```bash
TOKEN="$(./scripts/get-hospital-token.sh 3130400221)"
URL=https://localhost:5000/transform/cdrs

curl -k -sS -X POST "$URL" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(./scripts/dpop-proof.sh keys/3130400221.key.pem POST "$URL" "$TOKEN")" \
  -H 'Content-Type: application/json' \
  -d '[{
    "hospital_patient_number":"2405078",
    "encounter_number":"SMOKE-1",
    "first_name":"CHANDRIKA",
    "last_name":"KANDEL",
    "sex":"Female",
    "dob":"1990-01-15",
    "phone_number":"9841000001",
    "department_type":"C",
    "department_id":"22",
    "department_name":"Family Medicine",
    "visit_date_ad_time":"2026-07-28 00:02:00.000"
  }]'
```

The body is an array of up to 100 rows. Expect HTTP 200 with `{"correlationId": ..., "results": [...]}`, one result per row: `status` and the transaction-response `response` (the Patient with its nepal-health-id and jempi-golden-uid identifiers, and the Encounter), or `error`. A failed row fails alone; resend only that row. Send the same encounter_number again and its Encounter entry returns `200 OK`, not a new `201 Created`. The same person from a second hospital gets the same Health ID, and the Patient keeps both hospitals' MRNs, each on its hospital's own `hospital-mrn/<NHFR>` system.

Send `dob` whenever the source has it. Without dob and national ID, JeMPI scores even an exact name and phone match below the 0.9 link threshold, so each visit creates a new golden record. The admin review scan then lists those pairs for merging.

In OpenHIM Console → Transactions, the request shows the cdrs-v1 channel with the identity and HAPI orchestrations.

## Hospital adapter

The hospital-side adapter (`FHIR_mediator`) posts raw rows to `/transform/cdrs` and FHIR Bundles to `/fhir`. Set `OPENHIM_URL` in its `.env` to `PUBLIC_BASE_URL` (an older `INGEST_URL=<base>/ingest` still works; the adapter strips `/ingest`). An older adapter that posts to `/ingest` gets 404.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| JWT 401 with a valid token | Confirm `KEYCLOAK_ISSUER` equals the token `iss` claim exactly, and that `docker compose exec openhim-core wget -qO- $KEYCLOAK_ISSUER/protocol/openid-connect/certs` returns keys. |
| JWT 401 only for DPoP-bound tokens | The proof must be fresh (single-use `jti`, `iat` within 5 minutes), signed with the client's own key, and name the exact method and URL; `PUBLIC_BASE_URL` in .env must equal the scheme, host, and port the client calls. |
| Mediator restarts with OPENHIM_PASSWORD invalid | Update env/identity-mediator.env, env/transform-mediator.env and env/patient-portal-mediator.env with the mediators@openhim.local password, then recreate the mediators. A 403 at registration means the user is missing the mediator-registration role. |
| identity-mediator or patient-portal-mediator fails to start: key file missing | Onboard its client first ([First start](#first-start) step 4). If Docker created a directory at keys/<client>.key.pem, remove it and onboard again. |
| Keycloak token request: `DPoP proof is missing` | Expected for every confidential client: send a DPoP proof with the token request (`get-hospital-token.sh` does). |
| realm-management is missing in Keycloak roles | Select realm openhie, then use **Role mapping** → **Assign role** → **Filter by clients**. |
| Facility JWT receives 403 from OpenHIM | Check that the OpenHIM client ID, mapper sub, and NHFR Organization identifier all use the same NHFR code; verify role `hospital` or `laboratory`. |
| 403 from HAPI (OperationOutcome) | The token lacks the SMART scope for that resource and action, the record belongs to another facility, or a Patient write did not come through the identity mediator. Compare the token's `scope` claim with `keycloak/client-types.json`; rerun `onboard-client.sh` for the client after changing its type's scopes. |
| 400 `not-supported` on a search | Searches must name one patient (`patient`/`subject`, or `identifier`/`_id` on Patient); chained parameters, wildcard `_include` and Binary search are refused. |
| HAPI rejects a resource | Read the returned FHIR OperationOutcome. Request validation is enabled in hapi-config/application.yaml. |
| HAPI rejects every address (`HAPI-3004`) | The IG is not stored or not indexed. Confirm `installMode: STORE_AND_INSTALL` and the Lucene settings, then recreate HAPI with fresh `hapi-db-data` and `hapi-lucene-data` volumes. |

## Update images

OpenHIM Core and Console track the `master` tag of the etech-nepal forks (`ghcr.io/etech-nepal/openhim-core:master`, `ghcr.io/etech-nepal/openhim-console:master`). HAPI, the identity, transform and patient portal mediators use the tag OPENHIE_IMAGE_TAG from .env (the openhie commit SHA). To deploy a newer release, change it, then run:

```bash
docker compose pull
docker compose up -d
```
