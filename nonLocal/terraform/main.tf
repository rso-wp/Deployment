# RSO on Azure: AKS (platform services + NATS + Traefik), Azure Database for PostgreSQL (the services), Azure Database
# for MySQL (tenant WordPress databases), Storage Queues + a Flex Consumption Function App (ProvisionFunction).
# Plain HTTP; the app and the sites use sslip.io names built from the ingress IP. Steps: nonLocal/terraform/README.md.

terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm    = { source = "hashicorp/azurerm", version = "~> 4.40" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    random     = { source = "hashicorp/random", version = "~> 3.7" }
    tls        = { source = "hashicorp/tls", version = "~> 4.1" }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  name = "rso-${random_string.suffix.result}"

  # http://<ip-with-dashes>.sslip.io serves the app; sites are <site>.<tenant>.<that name>.
  base_domain = "${replace(azurerm_public_ip.ingress.ip_address, ".", "-")}.sslip.io"

  databases = ["UserServiceDb", "PaymentServiceDb", "ProvisioningServiceDb"]
  queues    = ["provision-site", "deprovision-site", "provisioning-events", "provisioning-events-poison"]

  pg_host    = azurerm_postgresql_flexible_server.pg.fqdn
  mysql_host = azurerm_mysql_flexible_server.mysql.fqdn
}

resource "azurerm_resource_group" "rso" {
  name     = var.resource_group_name
  location = var.location
}

# ------------------------------------------------------------------------------------------------ PostgreSQL

resource "random_password" "postgres" {
  length  = 32
  special = false # it goes into connection strings
}

resource "azurerm_postgresql_flexible_server" "pg" {
  name                          = "${local.name}-pg"
  resource_group_name           = azurerm_resource_group.rso.name
  location                      = azurerm_resource_group.rso.location
  version                       = "16"
  sku_name                      = var.postgres_sku
  storage_mb                    = 32768
  administrator_login           = "rsoadmin"
  administrator_password        = random_password.postgres.result
  public_network_access_enabled = true

  lifecycle {
    ignore_changes = [zone]
  }
}

# 0.0.0.0 = "allow Azure services": the AKS nodes reach the server over its public endpoint.
resource "azurerm_postgresql_flexible_server_firewall_rule" "azure" {
  name             = "allow-azure-services"
  server_id        = azurerm_postgresql_flexible_server.pg.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_postgresql_flexible_server_database" "db" {
  for_each  = toset(local.databases)
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.pg.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# ------------------------------------------------------------------------------------------------ MySQL (tenant sites)

resource "random_password" "mysql" {
  length  = 32
  special = false
}

# Its own region if needed: some subscriptions (e.g. Azure for Students) can't create MySQL in every region.
resource "azurerm_mysql_flexible_server" "mysql" {
  name                   = "${local.name}-mysql"
  resource_group_name    = azurerm_resource_group.rso.name
  location               = coalesce(var.mysql_location, azurerm_resource_group.rso.location)
  version                = "8.0.21"
  sku_name               = "B_Standard_B1ms"
  administrator_login    = "rsoadmin"
  administrator_password = random_password.mysql.result

  lifecycle {
    ignore_changes = [zone]
  }
}

resource "azurerm_mysql_flexible_server_firewall_rule" "azure" {
  name                = "allow-azure-services"
  resource_group_name = azurerm_resource_group.rso.name
  server_name         = azurerm_mysql_flexible_server.mysql.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# ------------------------------------------------------------------------------------------------ Storage (queues + function)

resource "azurerm_storage_account" "st" {
  name                     = "rso${random_string.suffix.result}st"
  resource_group_name      = azurerm_resource_group.rso.name
  location                 = azurerm_resource_group.rso.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_queue" "q" {
  for_each           = toset(local.queues)
  name               = each.key
  storage_account_id = azurerm_storage_account.st.id
}

# Where Flex Consumption keeps the deployed function package.
resource "azurerm_storage_container" "function_code" {
  name                  = "function-code"
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}

# ------------------------------------------------------------------------------------------------ AKS

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${local.name}-aks"
  resource_group_name = azurerm_resource_group.rso.name
  location            = azurerm_resource_group.rso.location
  dns_prefix          = local.name
  sku_tier            = "Free"

  default_node_pool {
    name                        = "system"
    vm_size                     = var.node_vm_size
    node_count                  = var.node_count
    os_disk_size_gb             = 32 # the default is 128 GB (a P10 disk, about four times the price of the 32 GB P4)
    temporary_name_for_rotation = "systemtmp"
  }

  identity {
    type = "SystemAssigned"
  }

  # Entra ID + Azure RBAC: ProvisionFunction's managed identity gets a role on the tenants namespace (below).
  # Local accounts stay on so terraform can use the admin kubeconfig.
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }
  local_account_disabled = false

  # Azure Monitor managed Prometheus: runs the ama-metrics agents. The workspace and rules are in monitoring.tf.
  dynamic "monitor_metrics" {
    for_each = var.enable_monitoring ? [1] : []
    content {}
  }

  # Azure CNI powered by Cilium, which enforces NetworkPolicies (tenant isolation below). Without a policy engine the
  # policies are accepted but do nothing.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
  }
}

# You (whoever runs terraform) can use kubectl with `az aks get-credentials` (no --admin needed).
resource "azurerm_role_assignment" "me_aks_admin" {
  scope                = azurerm_kubernetes_cluster.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Fixed public IP for the ingress, so the sslip.io names never change. In the node resource group, where AKS manages
# load balancer IPs.
resource "azurerm_public_ip" "ingress" {
  name                = "${local.name}-ingress"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  location            = azurerm_resource_group.rso.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ------------------------------------------------------------------------------------------------ Function App

resource "azurerm_service_plan" "function" {
  name                = "${local.name}-func-plan"
  resource_group_name = azurerm_resource_group.rso.name
  location            = azurerm_resource_group.rso.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "provision" {
  name                = "${local.name}-provision"
  resource_group_name = azurerm_resource_group.rso.name
  location            = azurerm_resource_group.rso.location
  service_plan_id     = azurerm_service_plan.function.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.st.primary_blob_endpoint}${azurerm_storage_container.function_code.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.st.primary_access_key

  runtime_name           = "dotnet-isolated"
  runtime_version        = var.function_dotnet_version
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  identity {
    type = "SystemAssigned"
  }

  site_config {}

  app_settings = {
    AzureWebJobsStorage = azurerm_storage_account.st.primary_connection_string
    # Queue triggers + event publisher authenticate with the managed identity (role below).
    ProvisioningQueues__queueServiceUri = trimsuffix(azurerm_storage_account.st.primary_queue_endpoint, "/")
    MySql__AdminConnectionString        = "Server=${local.mysql_host};Port=3306;User ID=rsoadmin;Password=${random_password.mysql.result};SslMode=Required"
    MySql__HostForSites                 = "${local.mysql_host}:3306"
    MySql__SitesUseTls                  = "true" # Azure Database for MySQL only accepts TLS

    # Sites as Deployments in AKS; the function signs in to the API server with its managed identity (role below).
    Sites__Backend            = "Kubernetes"
    Kubernetes__ApiServer     = azurerm_kubernetes_cluster.aks.kube_config[0].host
    Kubernetes__CaCertificate = azurerm_kubernetes_cluster.aks.kube_config[0].cluster_ca_certificate
    Kubernetes__Namespace     = "tenants"
    Kubernetes__IngressClass  = "traefik"
    Kubernetes__StorageClass  = var.site_storage_class
  }
}

resource "azurerm_role_assignment" "function_queues" {
  scope                = azurerm_storage_account.st.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.provision.identity[0].principal_id
}

# The function creates the WordPress sites (Secret, PVC, Deployment, Service, Ingress) in the tenants namespace.
resource "azurerm_role_assignment" "function_tenants" {
  scope                = "${azurerm_kubernetes_cluster.aks.id}/namespaces/tenants"
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azurerm_function_app_flex_consumption.provision.identity[0].principal_id
}

# ------------------------------------------------------------------------------------------------ In the cluster

locals {
  kube = azurerm_kubernetes_cluster.aks.kube_admin_config[0]
}

provider "kubernetes" {
  host                   = local.kube.host
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
    cluster_ca_certificate = base64decode(local.kube.cluster_ca_certificate)
  }
}

resource "kubernetes_namespace_v1" "ns" {
  for_each = toset(["messaging", "traefik", "rso", "tenants"])
  metadata {
    name = each.key
  }
}

# Customers control the code of their WordPress sites (plugins), so a site may only reach DNS and the internet (MySQL is
# reached on its public endpoint): not NATS (no auth), the platform services (PaymentService's gRPC port has no auth), the
# nodes or their metadata endpoint. Only Traefik connects to the sites. Cilium never matches cluster pods by CIDR, so the
# 0.0.0.0/0 rule does not admit them.
resource "kubernetes_network_policy_v1" "tenants" {
  metadata {
    name      = "tenant-isolation"
    namespace = kubernetes_namespace_v1.ns["tenants"].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "traefik" }
        }
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]
        }
      }
    }
  }
}

resource "helm_release" "nats" {
  name       = "nats"
  namespace  = kubernetes_namespace_v1.ns["messaging"].metadata[0].name
  repository = "https://nats-io.github.io/k8s/helm/charts/"
  chart      = "nats"
  version    = "2.15.1"

  values = [yamlencode({
    natsBox = { enabled = false } # a helper pod with the nats CLI; not needed
    config = {
      jetstream = {
        enabled   = true
        fileStore = { pvc = { size = "1Gi" } }
      }
    }
  })]
}

resource "helm_release" "traefik" {
  name       = "traefik"
  namespace  = kubernetes_namespace_v1.ns["traefik"].metadata[0].name
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = "42.0.0"

  values = [yamlencode({
    ingressClass = { enabled = true, isDefaultClass = true }
    service = {
      annotations = {
        "service.beta.kubernetes.io/azure-pip-name"                     = azurerm_public_ip.ingress.name
        "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_kubernetes_cluster.aks.node_resource_group
      }
    }
  })]
}

# Token signing key of UserService (only in the terraform state and the Secret below).
resource "tls_private_key" "signing" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

locals {
  # Maximum Pool Size: each service has two or three pools (EF Core, Wolverine, Marten), and the server's connection limit
  # is shared by all of them (B1ms: about 35 usable), so keep the pools small.
  pg = { for db in local.databases : db => "Host=${local.pg_host};Port=5432;Database=${db};Username=rsoadmin;Password=${random_password.postgres.result};Ssl Mode=Require;Maximum Pool Size=${var.postgres_max_pool_size}" }
}

# Secrets for the chart (its existingSecret values), so nothing secret goes through helm values.
resource "kubernetes_secret_v1" "user_service" {
  metadata {
    name      = "user-service-secrets"
    namespace = kubernetes_namespace_v1.ns["rso"].metadata[0].name
  }
  data = {
    ConnectionStrings__DefaultConnection = local.pg["UserServiceDb"]
    Auth__SigningKey                     = tls_private_key.signing.private_key_pem
  }
}

resource "kubernetes_secret_v1" "payment_service" {
  metadata {
    name      = "payment-service-secrets"
    namespace = kubernetes_namespace_v1.ns["rso"].metadata[0].name
  }
  data = {
    ConnectionStrings__DefaultConnection = local.pg["PaymentServiceDb"]
    Stripe__SecretKey                    = var.stripe_secret_key
    Stripe__WebhookSecret                = var.stripe_webhook_secret
  }
}

resource "kubernetes_secret_v1" "provisioning_service" {
  metadata {
    name      = "provisioning-service-secrets"
    namespace = kubernetes_namespace_v1.ns["rso"].metadata[0].name
  }
  data = {
    ConnectionStrings__DefaultConnection = local.pg["ProvisioningServiceDb"]
    ProvisioningQueues                   = azurerm_storage_account.st.primary_connection_string
  }
}

# Values of the rso chart: passed to its helm release below, or to the Argo CD Application (argocd.tf).
locals {
  rso_values = {
    global = {
      imageRegistry    = var.image_registry
      migrateOnStartup = true
    }
    nats = { url = "nats://nats.messaging:4222" }
    auth = { signingPublicKey = tls_private_key.signing.public_key_pem }
    gateway = {
      replicas = 1
      ingress  = { enabled = true, className = "traefik", host = local.base_domain }
    }
    frontend = { replicas = 1, image = { tag = var.image_tag } }
    userService = {
      image    = { tag = var.image_tag }
      database = { existingSecret = kubernetes_secret_v1.user_service.metadata[0].name }
      auth     = { existingSecret = kubernetes_secret_v1.user_service.metadata[0].name }
    }
    paymentService = {
      image    = { tag = var.image_tag }
      database = { existingSecret = kubernetes_secret_v1.payment_service.metadata[0].name }
      stripe = {
        existingSecret = kubernetes_secret_v1.payment_service.metadata[0].name
        publishableKey = var.stripe_publishable_key
      }
    }
    provisioningService = {
      image         = { tag = var.image_tag }
      database      = { existingSecret = kubernetes_secret_v1.provisioning_service.metadata[0].name }
      queues        = { existingSecret = kubernetes_secret_v1.provisioning_service.metadata[0].name }
      stripePriceId = var.stripe_price_id
      baseDomain    = local.base_domain
    }
  }
}

# Terraform installs the platform chart itself, unless Argo CD does it (deploy_repo_url set, see argocd.tf and the Argo CD section of the README).
moved {
  from = helm_release.rso
  to   = helm_release.rso[0]
}

resource "helm_release" "rso" {
  count     = local.argocd_enabled ? 0 : 1
  name      = "rso"
  namespace = kubernetes_namespace_v1.ns["rso"].metadata[0].name
  chart     = "${path.module}/../helm/rso"
  timeout   = 600

  values = [yamlencode(local.rso_values)]

  depends_on = [
    helm_release.nats,
    helm_release.traefik,
    azurerm_postgresql_flexible_server_database.db,
    azurerm_postgresql_flexible_server_firewall_rule.azure,
    azurerm_storage_queue.q,
  ]
}
