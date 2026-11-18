# Deploy RSO to Azure with Terraform

See also the [repository README](../../README.md) (layout, local setup, Argo CD).

`nonLocal/terraform` creates everything in one `terraform apply`, over plain HTTP:

| Azure resource | Used for |
|---|---|
| AKS cluster (1 node) | gateway, frontend, UserService, PaymentService, ProvisioningService, NATS, Traefik (ingress) |
| Static public IP | Traefik. The app is at `http://<ip-with-dashes>.sslip.io`, sites will be `http://<site>.<tenant>.<that>` |
| PostgreSQL Flexible Server | `UserServiceDb`, `PaymentServiceDb`, `ProvisioningServiceDb` (migrations run when the services start) |
| MySQL Flexible Server | tenant WordPress databases (used by ProvisionFunction) |
| Storage account | queues `provision-site`, `deprovision-site`, `provisioning-events`; the Function App's storage |
| Function App (Flex Consumption) | ProvisionFunction. Its managed identity can use the queues and the AKS `tenants` namespace |
| Azure Monitor workspace + Azure Managed Grafana (only with `enable_monitoring = true`) | managed Prometheus scrapes the services' `/metrics`; `grafana_url` is the Grafana (Entra ID sign-in). Grafana Standard is billed per instance and active user |

All secrets (database passwords, the token signing key, the Stripe keys) are generated or read from variables and stored as
Kubernetes Secrets, never in helm values. **They are also in the terraform state**, so keep `terraform.tfstate` private.

Terraform creates the Function App but doesn't deploy its code: **step 6 is needed before sites can be created.** Until
then a new site stays `Queued`.

Each site gets its own Azure Disk (`site_storage_class = managed-csi`), and a node can attach only a few disks: 4 on the
default `Standard_B2ms`, one of which NATS's JetStream volume takes. So plan on about 3 sites per node, or use a bigger
`node_vm_size` (e.g. `Standard_B4ms`: 8) or more nodes. A site beyond the limit stays `Pending`, becomes `Failed` after
about 45 minutes of retries, and is retried every hour after that, so it comes up once a disk slot is free.

## 1. Prerequisites

- **Tools:** Terraform 1.9 or newer, Azure CLI. Optional: `kubectl` (`az aks install-cli`), and Azure Functions Core Tools
  for step 6.
- **Images on Docker Hub:** push a git tag like `v0.1.0` in each service repository (its "Publish image" workflow pushes `armodilo/<image>:v0.1.0`), and use the same version as `image_tag` below. The repositories
  must be public; the chart's pull secret isn't wired into this config.
- **Stripe, test mode** (dashboard → Developers → API keys): the secret key `sk_test_...` and the publishable key
  `pk_test_...`. Then create a product with a **recurring** price, and note its `price_...` id.

## 2. Sign in to Azure

```powershell
az login
az account show --query "{name:name, id:id}"        # wrong one? az account set -s <id>

foreach ($ns in "Microsoft.ContainerService", "Microsoft.DBforPostgreSQL", "Microsoft.DBforMySQL",
                "Microsoft.Storage", "Microsoft.Web", "Microsoft.Network") {
  az provider register --namespace $ns
}
```

Registering the resource providers only matters for a new subscription. It is harmless otherwise.

## 3. Settings

```powershell
cd nonLocal/terraform
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

| Variable | |
|---|---|
| `subscription_id` | `az account show --query id -o tsv` |
| `location` | a region your subscription allows (student subscriptions are restricted; see troubleshooting) |
| `image_tag` | the `$Version` you pushed |
| `stripe_secret_key`, `stripe_publishable_key`, `stripe_price_id` | from step 1 |

Optional: `node_vm_size` (default `Standard_B2ms`), `node_count`, `image_registry`, `resource_group_name`.

## 4. Create everything

```powershell
terraform init
terraform apply          # review the plan, type yes. Takes about 15-20 minutes (AKS and the databases are the slow part)
terraform output
```

Then open `app_url` (for example `http://20-1-2-3.sslip.io`). The first request can take a minute while the services
migrate their databases. Then sign up, fill in your profile, and add a card (`4242 4242 4242 4242`, any future date, any
CVC).

To look inside the cluster:

```powershell
Invoke-Expression (terraform output -raw kubectl_credentials)
kubectl get pods -A
kubectl logs -n rso deploy/rso-user-service
```

## 5. Stripe webhook (failed payments shut sites down)

1. Stripe dashboard → Developers → Webhooks → add an endpoint at `terraform output -raw stripe_webhook_url`, for the
   events `invoice.payment_failed`, `customer.subscription.deleted` and `customer.subscription.updated`.
   Until the real signing secret is set, PaymentService logs an error at startup and its `/health/ready` reports
   `stripe-webhook-secret` as Degraded; failed payments are then only caught by its reconciliation (every 6 hours).
   If Stripe refuses the `http://` URL, use the Stripe CLI from your machine instead:
   `stripe listen --forward-to (terraform output -raw stripe_webhook_url)`. Use the `whsec_...` it prints, and keep it
   running while you test.
2. Add `stripe_webhook_secret = "whsec_..."` to `terraform.tfvars` and run `terraform apply`.
3. The services read their Secret only at start, so restart PaymentService:
   `kubectl rollout restart deploy/rso-payment-service -n rso`.

## 6. Publish ProvisionFunction (needed for sites)

The Function App exists, but terraform doesn't deploy code. Publish it once now, and again after every change to
`ProvisionFunction`:

```powershell
powershell -ExecutionPolicy Bypass -File nonLocal/publish-function.ps1
```

It builds the function, zips it and deploys it to `function_app_name`, then lists `ProvisionSite` and `DeprovisionSite`.
Don't zip it yourself with `Compress-Archive`: Azure rejects that zip ("Cannot find required .azurefunctions directory").
Terraform creates the Function App without its code; this script publishes it.

Then create a site in the app. After about 1-2 minutes it shows as running, with a link to
`http://<site>.<tenant>.<base_domain>` and the WordPress installer behind it. To watch it happen:

```powershell
kubectl get deploy,pods,pvc,ingress -n tenants
```

The function's logs are in the portal: Function App → Monitoring → Log stream.

## 7. The site domain in the frontend

The "your site will be at ..." preview in the UI uses `baseDomain` from `WordpressAsAServiceUi/src/app/core/config.ts`
(currently `mydomain.com`). That value is set at build time. Set it to `terraform output -raw base_domain`, then push a new
image version (step 8). The value only affects the preview text: ProvisioningService already uses the right domain.

## 8. Updating

- **New code:** push a new git tag (for example `v0.1.1`) in the service repository, then set `image_tag` to it and run
  `terraform apply`. Images are only pulled when the tag changes, so reusing a tag does nothing.
- **Configuration:** change `terraform.tfvars` and run `terraform apply`. If only a Secret changed, restart the
  deployment that uses it (as in step 5).

## 9. Stop or delete

```powershell
terraform destroy                                    # deletes everything (asks first)

# or pause and keep the data:
az aks stop -g rso-rg -n (terraform output -raw aks_name)
```

`terraform destroy` removes the public IP, so the sslip.io name changes on the next apply.

## Troubleshooting

| Problem | What to do |
|---|---|
| `LocationIsOfferRestricted`, `SkuNotAvailable`, or a quota error | Your subscription doesn't allow that size or region. Try another `location` (e.g. `northeurope`, `swedencentral`, `germanywestcentral`), or a different `node_vm_size` |
| The Function App fails with an unsupported runtime version | Flex Consumption doesn't offer .NET 10 in that region yet. `az functionapp list-flexconsumption-runtimes -l <location> --runtime dotnet-isolated` lists what it does offer. Use that version, and retarget `ProvisionFunction/Function` to the same framework |
| The first apply fails on a Kubernetes or Helm connection | Create the cluster first: `terraform apply -target azurerm_kubernetes_cluster.aks -target azurerm_public_ip.ingress`, then run `terraform apply` again |
| `helm_release.rso` times out | `kubectl get pods -n rso` and `kubectl logs`. Usually the images (wrong tag, or private repositories) or the database connection |
| The app URL doesn't respond | `kubectl get svc -n traefik`: EXTERNAL-IP should be the `base_domain` IP. `kubectl get ingress -n rso` |
| A site stays `Queued` | The function code isn't published (step 6), or it can't start: Function App → Log stream |
| A site becomes `Failed` | The function's log has the reason. `not scheduled ... node(s) exceed max volume count` means the node's disk limit (see the top); `ImagePullBackOff` means Docker Hub rate limits or no network |
| Every API call returns 401 after signing in | PaymentService and ProvisioningService get the signing key from UserService. Is `rso-user-service` running? |

## Keeping costs low

The defaults are the cheapest setup that still works for testing. Pay-as-you-go list prices in `spaincentral`
(November 2026, USD, running 24/7, 730 hours a month; Azure's public price list):

| Item | Setting | About per month |
|---|---|---|
| AKS node | `node_vm_size = "Standard_B2ms"` (8 GB) | $67 |
| | `"Standard_B2s"` (4 GB) | $33 |
| AKS node OS disk | `os_disk_size_gb = 32` (P4); the default is 128 GB (P10) | $5.8 instead of $21.7 |
| PostgreSQL | `postgres_sku = "B_Standard_B1ms"` | $14.5 |
| | `"B_Standard_B2s"` | $58 |
| MySQL | `B_Standard_B1ms` (already the smallest) | $14.5 |
| Grafana + managed Prometheus | `enable_monitoring = false` (default) | not created; Grafana is billed per instance |

What the defaults trade away:

- **PostgreSQL B1ms allows about 35 connections.** The three services share them, which is why `postgres_max_pool_size` is 5.
  Under load the pools can run out (sign-up and log-in then fail). Check with
  `select count(*) from pg_stat_activity;` and raise `postgres_sku` back to `B_Standard_B2s` if it gets close to 35.
- **The node stays on B2ms (8 GB).** B2s halves the node price, but platform + Argo CD + a few WordPress sites is tight in 4 GB
  (pods stay `Pending` or get evicted). Try it with `node_vm_size = "Standard_B2s"` once everything is deployed; changing the
  size replaces the node.
- **One replica** of the gateway and the frontend, no `nats-box` pod, no monitoring agents.
- **No Grafana.** Set `enable_monitoring = true` to bring it back (dashboards in Grafana are lost when it is switched off).

Fixed costs you can't remove: the Standard load balancer and public IP that AKS needs, the 32 GB minimum PostgreSQL disk,
and the disks of the WordPress sites (2 GB each).

### Stop everything while you are not testing

Stopped compute is not billed; the disks, the public IP and storage still are. Stop the databases too, they are
billed while they run:

```powershell
az aks stop -g rso-rg -n <aks_name>                       # terraform output aks_name
az postgres flexible-server list -g rso-rg -o table       # names of the two database servers
az postgres flexible-server stop -g rso-rg -n <postgres name>
az mysql flexible-server stop -g rso-rg -n <mysql name>
```

Start them in this order, databases first: `az postgres flexible-server start ...`, `az mysql flexible-server start ...`,
then `az aks start ...`. Azure starts a stopped database server by itself after 7 days. `terraform apply` needs the cluster
running.

## Central logging

UserService, PaymentService, ProvisioningService and ProvisionFunction send their logs to **Application Insights**, which
stores them in a **Log Analytics workspace** (`enable_logging`, on by default). Grafana only displays logs, it cannot store
them; Azure Managed Grafana reads this workspace with its built-in Azure Monitor data source.

- **Services.** The C# services export everything written through `ILogger` with an OpenTelemetry exporter, switched on by
  the `APPLICATIONINSIGHTS_CONNECTION_STRING` setting. Terraform puts it in a Secret (`logging`) and the chart gives it to the
  three pods (`global.logging.existingSecret`). Without the setting (local runs) nothing leaves the process. The console output
  stays, so `kubectl logs` still works.
- **Function.** The Function App gets the same connection string, and the Functions host sends its logs (and the worker's)
  to Application Insights, no code change.
- **Cost.** The first 5 GB a month are free. `log_daily_cap_gb` (default 0.15, about 4.5 GB a month) makes the workspace stop
  taking in data when it is reached, until the next day; retention is 30 days (`log_retention_days`).
- **Only new versions log.** The services have to be released again (a new `vX.Y.Z` tag in each repository) before they
  export anything; Terraform and the chart only prepare the setting.

### Read the logs

In the Azure portal: the Log Analytics workspace (`terraform output logs` names it) or the Application Insights resource, then
**Logs**. Useful queries (the "role name" is the service):

```kusto
AppTraces | where AppRoleName == "user-service" | order by TimeGenerated desc
AppTraces | where SeverityLevel >= 3 | order by TimeGenerated desc          // warnings and errors, all services
AppTraces | where Message contains "ProvisionId" | order by TimeGenerated desc
AppExceptions | order by TimeGenerated desc
```

### Read them in Grafana

Grafana is off by default (it is billed per instance). Set `enable_monitoring = true` and run `terraform apply`; Terraform also
gives Grafana's identity the **Log Analytics Reader** role on the workspace. In Grafana (`terraform output grafana_url`):
**Explore** -> data source **Azure Monitor** -> service **Logs** -> pick the workspace -> paste a query like the ones above. A
dashboard panel with a table or "Logs" visualization uses the same query. Metrics are in the Prometheus data source.
