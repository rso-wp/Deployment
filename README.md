# Deployment

How RSO (a WordPress-as-a-service platform) is run locally and on Azure: docker compose for development, Terraform and
Helm for AKS, and Argo CD to roll out new images. The services themselves live in their own repositories:
UserService, PaymentService, ProvisioningService, ProvisionFunction and WordpressAsAServiceUi.

> **This repository is public. Never commit secrets**: `terraform.tfstate*`, `terraform.tfvars` (Stripe keys), tokens.
> The `.gitignore` excludes them; keep it that way.

## Layout

```
local/                      development on your machine
  docker-compose.yml        Postgres, MySQL, NATS, Azurite, Keycloak ... and (profile "apps") the services
  keycloak/rso-realm.json   the Keycloak realm (sign-up on, the web app's client, the API audience), imported on first start
  gateway/nginx.conf        the API gateway of the compose setup
  run-local.ps1             compose + every service with `dotnet run`
  send-stripe-event.py      sends a signed fake Stripe webhook to PaymentService
nonLocal/                   Azure
  terraform/                everything on Azure: AKS, PostgreSQL, MySQL, storage queues, the Function App, monitoring,
                            Traefik, NATS, and optionally Argo CD (README.md in that folder has the full steps)
  helm/rso/                 the platform chart (gateway, frontend, UserService, PaymentService, ProvisioningService, Keycloak)
  helm/argocd-config/       a small chart Terraform installs: the Argo CD Application + the Image Updater resource
  publish-function.ps1      builds ProvisionFunction and deploys it to the Function App
```

The scripts expect the service repositories next to this one:

```
<root>/Deployment  <root>/UserService  <root>/PaymentService  <root>/ProvisioningService  <root>/ProvisionFunction
```

## Local

```powershell
powershell -ExecutionPolicy Bypass -File local/run-local.ps1      # infrastructure + services
docker compose -f local/docker-compose.yml down                  # stop the infrastructure
```

Sign-up and log-in are Keycloak's: open the web app (`npm start` in WordpressAsAServiceUi, http://localhost:4200), click
**Create account**, and Keycloak's page (http://localhost:8180) takes the details. Keycloak's admin console is on
http://localhost:8180 (user `admin`, password `admin`; local only).

## Identity: Keycloak and how it ties together

**Keycloak owns the accounts** (sign-up, log-in, passwords, lockout, tokens). **UserService owns the profile** (name, company,
tenant) and the GraphQL API. The two are linked by one id: the user's Keycloak id, which is the `sub` of every token and the
user id in every service.

```mermaid
sequenceDiagram
    actor U as User (browser)
    participant W as Web app
    participant K as Keycloak
    participant US as UserService (GraphQL)
    participant N as NATS
    participant P as PaymentService
    U->>W: open the app, click Create account / Sign in
    W->>K: redirect to Keycloak's page
    U->>K: email, name, password (sign-up) or credentials (log-in)
    K-->>W: redirect back with a code; the app exchanges it for tokens
    W->>US: GraphQL me (Authorization: Bearer access token)
    US->>K: (once, cached) signing keys from the discovery document
    Note over US: token valid: signature, issuer, audience rso-api
    alt first time this user (sub) is seen
        US->>US: create the profile (id, email, first and last name from the token)
        US->>N: UserCreated (outbox, same transaction)
        N->>P: UserCreated: create the Stripe customer
    end
    US-->>W: the profile
    W->>US: patchMe (name, company): tenant slug assigned, TenantAssigned published
    W->>P: REST with the same token (PaymentService validates it itself)
```

### The new-user event

Before, UserService did the sign-up, so it published `UserCreated` right then. Now Keycloak does the sign-up and tells
nobody, so UserService first hears of a user **when that user's token arrives**: the first `me` (or `patchMe`) call creates the
profile and publishes `UserCreated`, in one transaction (the outbox), exactly once. The web app asks for the profile right
after the redirect back from Keycloak, so in practice this is the same moment as before.

What this means:

- **`UserCreated` is lazy.** A user who registers in Keycloak but never reaches the app has no profile and no Stripe customer.
  PaymentService creates a missing Stripe customer on demand anyway (when a card is added or a site is bought), so nothing
  breaks.
- **Name prefill.** Keycloak's sign-up form asks for first and last name; the profile is created with them, so the app's welcome
  page only needs the company before the tenant slug is assigned.
- **Two requests at once** (the app asks twice): one creates the profile, the other finds it (the unique key on the id decides;
  no duplicate event).
- **Changes in Keycloak.** A changed email is copied to the profile on the next request. A user **deleted in Keycloak keeps
  their profile and sites** (Keycloak sends no event); remove them yourself if that matters.
- **Everything after that is as before:** tenant slug, `TenantAssigned`, the provisioning flow.
- If you ever need the event at sign-up time (not at first use), the options are a Keycloak event listener that calls
  UserService, or a periodic sync through Keycloak's admin API. Neither is needed for this setup.

### Who validates what

| | |
|---|---|
| Browser -> Keycloak | the sign-in and sign-up pages, token refresh (the web app, `keycloak-js`, authorization code flow) |
| UserService, PaymentService, ProvisioningService | validate the access token themselves: signature (keys from Keycloak's discovery document, read inside the cluster), issuer (`iss`, the public address of the realm), audience (`rso-api`, added by a mapper of the realm's client) |
| Keycloak -> database | its own `KeycloakDb` on the same PostgreSQL server (small connection pool: the server allows few connections) |
| UserService -> database | the profile table only (id, email, name, company, tenant); no passwords any more |

### Keycloak on Azure

Terraform creates `KeycloakDb`, the admin password and a Secret; the chart deploys Keycloak and an Ingress at
`http://keycloak.<base domain>`; `terraform output keycloak` shows the address and how to get the admin password.

- **Plain http.** Everything is plain http (sslip.io), so the realm has "require SSL" off and the web app skips PKCE, which
  browsers only allow on https or localhost. Fine for testing; with a real domain and https, set `keycloak.sslRequired` and
  `auth.issuer` in the chart and re-enable PKCE (the app does it by itself on https).
- **The realm is imported once**, on Keycloak's first start, with the web app's address of that moment. A new public IP (a
  fresh `terraform apply`) means a new database and a new import, so that is fine; to change it later use the admin console.
- **The admin console needs one command.** Keycloak's built-in `master` realm (where the admin console lives) requires https
  for non-local addresses, and our realm's "SSL required: none" does not cover it. Over plain http, switch it off once, from
  inside the pod (a local address), then sign in at `http://keycloak.<base domain>/admin`:

  ```powershell
  kubectl -n rso exec deploy/rso-keycloak -- sh -c '/opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" && /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE'
  ```

  (Not tried against a live cluster. The sign-in and sign-up pages of the app do not need this.)
- **Memory.** Keycloak is a Java application and takes roughly 0.7 to 1.5 GB on the single node.
- **Passwords.** The realm requires 8+ characters and locks an account after 5 failed attempts. "Forgot password" and email
  verification are off: they need an email server (SMTP) configured in the realm.

## Azure

Follow [nonLocal/terraform/README.md](nonLocal/terraform/README.md): images, `terraform apply`, publishing the function,
first run. The images are published by the **Publish image** workflow of each service repository when you push a tag like
`v1.2.3` (`armodilo/<image>:v1.2.3` on Docker Hub).

## Central logging

The services and the function send their logs to Application Insights (Log Analytics), where you search them in the Azure portal
or read them in Grafana. On by default, with a daily size cap. See "Central logging" in
[nonLocal/terraform/README.md](nonLocal/terraform/README.md). Only service versions released after this change log there.

## Argo CD: new tags deploy themselves

Optional, off by default. With it on, tagging a service is the whole release:

```
tag v1.2.3 in a service repo -> GitHub pushes armodilo/<service>:v1.2.3 -> Argo CD Image Updater sets the new tag
-> Argo CD rolls it out
```

Both run in the cluster, so after `az aks start` they catch up on whatever changed while it was stopped.

1. Set the URL of **this** repository in `nonLocal/terraform/terraform.tfvars` (not committed):

   ```hcl
   deploy_repo_url = "https://github.com/<you>/Deployment.git"
   # deploy_repo_path = "nonLocal/helm/rso"   # default: where the platform chart is in this repository
   # image_version_constraint = ">=0.0.0"     # which tags may be deployed, e.g. "1.x"
   ```

   For a public repository Argo CD needs no credentials.
2. Hand the chart over from Terraform to Argo CD. Without downtime: `terraform state rm 'helm_release.rso[0]'`, then
   `terraform apply`. Otherwise just `terraform apply`: the platform is down for a few minutes while Argo CD reinstalls it.
   The cluster must be running for any `apply`.
3. Look at it:

   ```powershell
   kubectl -n argocd port-forward svc/argocd-server 8080:443         # https://localhost:8080, user: admin
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'   # base64 encoded
   kubectl -n argocd get application rso
   kubectl -n argocd get imageupdater rso -o yaml                    # when it last checked, what it updated
   ```

   To open the web UI without a port-forward, set `expose_argocd_ui = true` in `terraform.tfvars` and `terraform apply`: it is
   then at `http://argocd.<base domain>` (`terraform output argocd_url`), user `admin`. It is **plain HTTP**, so the admin
   password travels unencrypted: use it for testing only and set it back to `false` (or leave it off) otherwise.

From then on the chart in `nonLocal/helm/rso` is what Argo CD deploys: **change the chart here, not in a copy**. `image_tag`
in Terraform only seeds the starting tags; Image Updater sets the real ones (semver tags only, the `v` prefix is fine).
Turning it off again: set `deploy_repo_url = ""` and `terraform apply`.

Notes:

- Image Updater stores the chosen tag on the Argo CD Application (a Helm parameter), not in git: git does not show the
  deployed version.
- ProvisionFunction runs outside the cluster and is not updated by Argo CD (`nonLocal/publish-function.ps1`).
- The Kubernetes Secrets, NATS, Traefik, namespaces, the databases and the network policy stay in Terraform.
