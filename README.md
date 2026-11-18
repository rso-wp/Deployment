# Deployment

How RSO (a WordPress-as-a-service platform) is run locally and on Azure: docker compose for development, Terraform and
Helm for AKS, and Argo CD to roll out new images. The services themselves live in their own repositories:
UserService, PaymentService, ProvisioningService, ProvisionFunction and WordpressAsAServiceUi.

> **This repository is public. Never commit secrets**: `terraform.tfstate*`, `terraform.tfvars` (Stripe keys), tokens.
> The `.gitignore` excludes them; keep it that way.

## Layout

```
local/                      development on your machine
  docker-compose.yml        Postgres, MySQL, NATS, Azurite, ... and (profile "apps") the services
  gateway/nginx.conf        the API gateway of the compose setup
  run-local.ps1             compose + every service with `dotnet run`
  send-stripe-event.py      sends a signed fake Stripe webhook to PaymentService
nonLocal/                   Azure
  terraform/                everything on Azure: AKS, PostgreSQL, MySQL, storage queues, the Function App, monitoring,
                            Traefik, NATS, and optionally Argo CD (README.md in that folder has the full steps)
  helm/rso/                 the platform chart (gateway, frontend, UserService, PaymentService, ProvisioningService)
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

From then on the chart in `nonLocal/helm/rso` is what Argo CD deploys: **change the chart here, not in a copy**. `image_tag`
in Terraform only seeds the starting tags; Image Updater sets the real ones (semver tags only, the `v` prefix is fine).
Turning it off again: set `deploy_repo_url = ""` and `terraform apply`.

Notes:

- Image Updater stores the chosen tag on the Argo CD Application (a Helm parameter), not in git: git does not show the
  deployed version.
- ProvisionFunction runs outside the cluster and is not updated by Argo CD (`nonLocal/publish-function.ps1`).
- The Kubernetes Secrets, NATS, Traefik, namespaces, the databases and the network policy stay in Terraform.
