variable "subscription_id" {
  description = "Azure subscription to deploy into (az account show --query id -o tsv)."
  type        = string
}

variable "location" {
  description = "Azure region. Student subscriptions only allow some regions."
  type        = string
  default     = "francecentral"
}

variable "mysql_location" {
  description = "Region of the MySQL server; empty = location. For subscriptions that can't create MySQL in location (ProvisionNotSupportedForRegion)."
  type        = string
  default     = ""
}

variable "monitoring_location" {
  description = "Region of the Azure Monitor workspace (Prometheus) and its data collection rule; empty = location."
  type        = string
  default     = ""
}

variable "grafana_location" {
  description = "Region of Azure Managed Grafana. It is not offered in spaincentral, and student subscriptions only allow norwayeast, switzerlandnorth, francecentral, swedencentral, spaincentral (policy), so pick one of the first four. It can differ from the workspace's region."
  type        = string
  default     = "francecentral"
}

variable "grafana_major_version" {
  description = "Azure Managed Grafana major version (the Standard SKU accepts 12 and 13)."
  type        = string
  default     = "12"
}

variable "resource_group_name" {
  type    = string
  default = "rso-rg"
}

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server size, shared by the three services. B_Standard_B1ms allows only ~35 connections, which the services' pools can use up under load (then sign-up and log-in fail too); B_Standard_B2s allows ~400 and costs about twice as much."
  type        = string
  default     = "B_Standard_B2s"
}

variable "node_vm_size" {
  description = "AKS node size. 8 GB fits the platform plus ~15 WordPress sites."
  type        = string
  default     = "Standard_B2ms"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "site_storage_class" {
  description = "StorageClass of each WordPress site's volume. managed-csi = an Azure Disk per site (note: a node can attach only a few disks, 4 on Standard_B2ms)."
  type        = string
  default     = "managed-csi"
}

variable "image_registry" {
  description = "Registry + user of the images pushed by the Publish image workflows of the service repositories."
  type        = string
  default     = "docker.io/armodilo"
}

variable "image_tag" {
  description = "Tag of every platform image (the git tag the images were published with, e.g. v0.1.0)."
  type        = string
  default     = "v0.1.0"
}

variable "function_dotnet_version" {
  description = "dotnet-isolated version of the Function App (the project targets net10.0)."
  type        = string
  default     = "10.0"
}

variable "stripe_secret_key" {
  description = "sk_test_..."
  type        = string
  sensitive   = true
}

variable "stripe_publishable_key" {
  description = "pk_test_..."
  type        = string
}

variable "stripe_price_id" {
  description = "price_... of the recurring WordPress price."
  type        = string
}

variable "stripe_webhook_secret" {
  description = "whsec_... of the webhook endpoint (output stripe_webhook_url). A placeholder works until you create it."
  type        = string
  sensitive   = true
  default     = "whsec_not_set_yet"
}

# ------------------------------------------------------------------------------------------------ Argo CD (argocd.tf)

variable "deploy_repo_url" {
  description = "Git repository that contains the rso chart. Empty (default): Terraform installs the chart itself, as before. Set: Argo CD deploys it from there and Argo CD Image Updater keeps the image tags current (see the README)."
  type        = string
  default     = ""
}

variable "deploy_repo_revision" {
  description = "Branch (or tag) of deploy_repo_url that Argo CD follows."
  type        = string
  default     = "main"
}

variable "deploy_repo_path" {
  description = "Directory of the rso chart inside deploy_repo_url."
  type        = string
  default     = "nonLocal/helm/rso"
}

variable "deploy_repo_username" {
  description = "Only for a private deploy repo: username (any name works with a GitHub token)."
  type        = string
  default     = ""
}

variable "deploy_repo_password" {
  description = "Only for a private deploy repo: an access token that can read it (GitHub: fine-grained token, Contents: read)."
  type        = string
  sensitive   = true
  default     = ""
}

variable "image_version_constraint" {
  description = "Which tags Argo CD Image Updater may deploy: a semver constraint such as \">=0.0.0\" (any release), \"1.x\" or \"~1.2\". A \"v\" prefix on the tags is fine."
  type        = string
  default     = ">=0.0.0"
}
