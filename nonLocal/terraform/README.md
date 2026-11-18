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
| Azure Monitor workspace + Azure Managed Grafana | managed Prometheus scrapes the services' `/metrics`; `grafana_url` is the Grafana (Entra ID sign-in). Grafana Standard is billed per instance and active user |

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
