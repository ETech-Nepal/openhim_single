# OpenHIE single-stack deployment

This folder runs OpenHIM, Keycloak, HAPI FHIR, MongoDB, PostgreSQL, and four published mediator images. Every API client authenticates with a DPoP-bound Keycloak token (RFC 9449). It does not need the application source tree.

## Requirements

Install Docker Engine with the Docker Compose plugin. Install curl, jq, and openssl before onboarding hospitals.

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

| File                            | Required values                                                                                                                         |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| .env                            | Local defaults work on one machine. For a domain deployment, set DOMAIN, KEYCLOAK_PUBLIC_URL, and KEYCLOAK_ISSUER to public HTTPS URLs, and PUBLIC_BASE_URL to the URL clients call OpenHIM on (https://openhim.<DOMAIN>). DPoP proofs must name that exact URL. |
| env/mediator.env                | Set OPENHIM_PASSWORD; keep JEMPI_BASE_URL=http://202.51.71.81:50000/JeMPI.                                                              |
| env/fhir-intake-mediator.env    | Set OPENHIM_PASSWORD.                                                                                                                   |
| env/admin-mediator.env          | Set OPENHIM_PASSWORD; keep JEMPI_BASE_URL=http://202.51.71.81:50000/JeMPI.                                                              |
| env/patient-portal-mediator.env | Set OPENHIM_PASSWORD and a strong PORTAL_PATIENT_SHARED_SECRET if you use a patient portal.                                             |

The .env and env/\*.env files contain secrets and stay ignored by Git.

## Start and check the stack

```bash
docker compose pull
docker compose config --quiet
docker compose up -d
docker compose ps
```

| Service                | URL                        |
| ---------------------- | -------------------------- |
| OpenHIM Console        | http://localhost:9000      |
| OpenHIM Core API       | https://localhost:8080     |
| HAPI FHIR              | http://localhost:8081/fhir |
| Keycloak Admin Console | http://localhost:8083      |

OpenHIM verifies client JWTs against the realm JWKS (KEYCLOAK_JWKS_URI), fetched live and cached. No key file is needed, and the URL must be reachable from inside the openhim-core container. A token that carries `cnf.jkt` is accepted only with a matching `DPoP` proof whose `htu` is `PUBLIC_BASE_URL` plus the request path; each proof is single-use.

```bash
curl -kfsS https://localhost:8080/heartbeat
curl -fsS http://localhost:8081/fhir/metadata
```

## First OpenHIM login

1. Open the OpenHIM Console.
2. Sign in as root@openhim.org with the initial password openhim-password.
3. Change the root password in the Console. Change it there, not with a plain `PUT /users` API call: the mediators log in with OpenHIM's token scheme, and only the Console updates that password hash too.
4. Put the new password in OPENHIM_PASSWORD in all four files under env/.
5. Recreate the mediators.

```bash
docker compose up -d --force-recreate mediator fhir-intake-mediator admin-mediator patient-portal-mediator
```

An Invalid env config error with an empty OPENHIM_PASSWORD means one of those files still has the placeholder value.

## NP Core IG 1.0.0

HAPI loads `hapi-config/np.core-1.0.0.tgz` (canonical `http://fhir.digitalhealth.gov.np/core`)
and validates every write against the profiles a resource declares. Two settings in
`hapi-config/application.yaml` are required, or every Nepal address is rejected:
`installMode: STORE_AND_INSTALL` and the Lucene index on the `hapi-lucene-data`
volume. Check after the first start (the IG loads in the background; allow a few minutes):

```bash
curl -s 'http://localhost:8081/fhir/ValueSet/$expand?url=http://fhir.digitalhealth.gov.np/core/ValueSet/nepal-province-vs' | jq .expansion.total   # 7
```

## Keycloak realm

Keycloak imports the openhie realm automatically. Do not run the old extract-realm-pubkey.sh workflow; OpenHIM reads signing keys from the realm JWKS endpoint.

In the OpenHIM Console, confirm these channels:

| Channel                 | Role                   |
| ----------------------- | ---------------------- |
| NP FHIR Orchestrator    | np-fhir-clients        |
| NP FHIR Intake          | np-fhir-clients        |
| NP Patient Admin Review | np-admin-clients       |
| NP Patient Portal       | patient-portal-clients |

## Create a Keycloak client administrator

Use this account to manage hospital clients in realm openhie. It gets realm-management/manage-clients instead of full realm administration.

### Manual

1. In Keycloak, select realm **openhie**.
2. Go to **Users** → **Add user**. Create hie-client-admin and enable it.
3. Open **Credentials** and set a permanent password.
4. Open **Role mapping** → **Assign role**.
5. Choose **Filter by clients**, select **realm-management**, check **manage-clients**, and assign it.
6. Keycloak may also show create-client. Keep it assigned.

If you only see account/manage-account roles, click **Assign role** first. The realm-management roles are in the client-role filter. Confirm the active realm is openhie, not master.

### Optional script

```bash
./scripts/create-realm-client-admin.sh
```

The script prompts for the Keycloak bootstrap administrator password and the new hie-client-admin password. It does not place either password in shell history.

## Onboard a hospital

Each hospital needs four matching records:

1. A HAPI Organization whose NHFR identifier is the hospital's NHFR code.
2. A local RSA private key and a Keycloak private_key_jwt client.
3. A Keycloak mapper that sets the access-token sub claim to the NHFR code.
4. An OpenHIM client with the same NHFR code and role np-fhir-clients.

Use a real NHFR code in place of 3130400221.

### Manual onboarding

#### 1. Create the HAPI Organization

Open http://localhost:8081 and create an Organization with this body:

```json
{
  "resourceType": "Organization",
  "active": true,
  "name": "Bharatpur Hospital",
  "identifier": [
    {
      "use": "official",
      "type": {
        "coding": [
          {
            "system": "http://terminology.hl7.org/CodeSystem/v2-0203",
            "code": "FI"
          }
        ]
      },
      "system": "http://nhfr.digitalhealth.gov.np",
      "value": "3130400221"
    }
  ]
}
```

Search Organization by identifier first. Keep exactly one Organization for each NHFR code.

#### 2. Generate the hospital keypair

```bash
mkdir -p keys
chmod 700 keys
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out keys/3130400221.key.pem
openssl pkey -in keys/3130400221.key.pem -pubout \
  -out keys/3130400221.pub.pem
chmod 600 keys/3130400221.key.pem
```

#### 3. Create the Keycloak client

Log in as hie-client-admin and select realm **openhie**.

1. Go to **Clients** → **Create client**.
2. Choose OpenID Connect; set Client ID to 3130400221.
3. Enable **Client authentication** and **Service accounts roles**.
4. Disable **Standard flow** and save.
5. Open **Credentials**. Set the client authenticator to **Signed JWT** and signing algorithm to RS256.
6. Open **Keys**. Disable **Use JWKS URL**, then import keys/3130400221.pub.pem.
7. Open **Advanced** → **Advanced settings**. Turn on **OAuth 2.0 DPoP Bound Access Tokens Enabled** and save.

#### 4. Add the NHFR subject mapper

Open **Client scopes** → **3130400221-dedicated** → **Mappers**.

Click **Configure a new mapper**, then choose **Hardcoded claim**.

| Field               | Value       |
| ------------------- | ----------- |
| Name                | sub-as-client-id |
| Token Claim Name    | sub         |
| Claim value         | 3130400221  |
| Claim JSON Type     | String      |
| Add to access token | On          |
| Add to ID token     | Off         |
| Add to userinfo     | Off         |

Save the mapper.

#### 5. Create the OpenHIM client

Open the OpenHIM Console as the root user.

1. Go to **Clients** → **+ Client**.
2. Set Client ID to 3130400221.
3. Set the name to Bharatpur Hospital.
4. Add role np-fhir-clients.
5. Leave Basic-auth credentials empty. The hospital uses its Keycloak JWT.
6. Save.

Transfer keys/3130400221.key.pem to the hospital through a secure channel. Remove your local copy after transfer.

### Optional script

```bash
./scripts/onboard-hospital.sh 3130400221 "Bharatpur Hospital"
```

The script prompts for the hie-client-admin password. It creates the HAPI Organization, then runs `scripts/onboard-client.sh`, which creates the keypair, the DPoP-bound Keycloak client, the mapper, and the OpenHIM client (through the OpenHIM API, using OPENHIM_PASSWORD from env/mediator.env). It stores the private key in keys/, which Git ignores.

## Onboard admin and portal clients

Admin portal and patient portal backends use the same flow with a different OpenHIM role and no HAPI Organization:

```bash
./scripts/onboard-client.sh admin-portal "Patient Admin Portal" np-admin-clients
./scripts/onboard-client.sh patient-portal "Patient Portal BFF" patient-portal-clients
```

A hospital token is refused on `/admin` and `/patient-portal`, and the reverse holds too.

## Troubleshooting

| Symptom                                         | Check                                                                                                                                   |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| JWT 401 with a valid token                       | Confirm `KEYCLOAK_ISSUER` equals the token `iss` claim exactly, and that `docker compose exec openhim-core wget -qO- $KEYCLOAK_ISSUER/protocol/openid-connect/certs` returns keys. |
| JWT 401 only for DPoP-bound tokens              | The proof must be fresh (single-use `jti`, `iat` within 5 minutes), signed with the client's own key, and name the exact method and URL; `PUBLIC_BASE_URL` in .env must equal the scheme, host, and port the client calls. |
| Mediator restarts with OPENHIM_PASSWORD invalid | Update all four env/\*.env files with the current OpenHIM root password, then recreate mediators.                                       |
| realm-management is missing in Keycloak roles   | Select realm openhie, then use **Role mapping** → **Assign role** → **Filter by clients**.                                              |
| Hospital JWT receives 403 from OpenHIM          | Check that the OpenHIM client ID, mapper sub, and NHFR Organization identifier all use the same NHFR code; verify role np-fhir-clients. |
| HAPI rejects a resource                         | Read the returned FHIR OperationOutcome. Request validation is enabled in hapi-config/application.yaml.                                 |
| HAPI rejects every address (`HAPI-3004`)        | The IG is not stored or not indexed. Confirm `installMode: STORE_AND_INSTALL` and the Lucene settings, then recreate HAPI with fresh `hapi-db-data` and `hapi-lucene-data` volumes. |

## Update images

The Compose file pins the custom mediator images to a commit SHA. To deploy a newer release, replace the four GHCR SHA tags in docker-compose.yml, then run:

```bash
docker compose pull
docker compose up -d
```

## Ingest smoke test

Finish hospital onboarding first. `get-hospital-token.sh` signs the client assertion with the hospital's private key and sends a DPoP proof, so Keycloak binds the token to that key. Every OpenHIM call then needs a fresh proof from `dpop-proof.sh` with the same key, method, and URL.

```bash
TOKEN="$(./scripts/get-hospital-token.sh 3130400221)"
URL=https://localhost:5000/ingest

curl -k -sS -X POST "$URL" \
  -H "Authorization: DPoP $TOKEN" \
  -H "DPoP: $(./scripts/dpop-proof.sh keys/3130400221.key.pem POST "$URL" "$TOKEN")" \
  -H 'Content-Type: application/json' \
  -d '{
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
  }'
```

Expect HTTP 200 with a transaction-response Bundle: the Patient (with nepal-health-id and jempi-golden-uid identifiers) and the Encounter. Send the same encounter_number again and confirm the Encounter entry returns `200 OK`, not a new `201 Created`. The same person from a second hospital gets the same Health ID, and the Patient keeps both hospitals' MRNs.

Send `dob` whenever the source has it. Without dob and national ID, JeMPI scores even an exact name and phone match below the 0.9 link threshold, so each visit creates a new golden record. The admin review scan then lists those pairs for merging.

In OpenHIM Console → Transactions, the request shows the NP FHIR Intake channel with the JeMPI and HAPI orchestrations.
