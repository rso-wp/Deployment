# Optional (var.enable_monitoring, off by default: Grafana is billed per instance).
# Metrics: the services expose OpenTelemetry metrics at /metrics (Prometheus format). Azure Monitor managed Prometheus
# (the ama-metrics agents AKS runs once `monitor_metrics` is on) scrapes the pods annotated prometheus.io/scrape by the
# helm chart, stores the samples in an Azure Monitor workspace, and Azure Managed Grafana reads them from there.

locals {
  monitoring_location = coalesce(var.monitoring_location, azurerm_resource_group.rso.location)
}

resource "azurerm_monitor_workspace" "prometheus" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${local.name}-prometheus"
  resource_group_name = azurerm_resource_group.rso.name
  location            = local.monitoring_location
}

# Ingestion path from the cluster to the workspace: endpoint + rule + associations (what `az aks update --enable-azure-monitor-metrics` creates).
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${local.name}-prom-dce"
  resource_group_name = azurerm_resource_group.rso.name
  location            = local.monitoring_location
  kind                = "Linux"
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  count                       = var.enable_monitoring ? 1 : 0
  name                        = "${local.name}-prom-dcr"
  resource_group_name         = azurerm_resource_group.rso.name
  location                    = local.monitoring_location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus[0].id
  kind                        = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.prometheus[0].id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }
}

# The association with this exact name points the agents at the endpoint.
resource "azurerm_monitor_data_collection_rule_association" "endpoint" {
  count                       = var.enable_monitoring ? 1 : 0
  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_kubernetes_cluster.aks.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus[0].id
}

resource "azurerm_monitor_data_collection_rule_association" "rule" {
  count                   = var.enable_monitoring ? 1 : 0
  name                    = "${local.name}-prom-dcra"
  target_resource_id      = azurerm_kubernetes_cluster.aks.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus[0].id
}

# Besides the default targets (kubelet, cAdvisor, node exporter, kube-state-metrics), scrape annotated pods in the rso namespace.
resource "kubernetes_config_map_v1" "ama_metrics_settings" {
  count = var.enable_monitoring ? 1 : 0
  metadata {
    name      = "ama-metrics-settings-configmap"
    namespace = "kube-system"
  }

  data = {
    schema-version                = "v1"
    config-version                = "ver1"
    pod-annotation-based-scraping = "podannotationnamespaceregex = \"rso\""
  }

  depends_on = [azurerm_monitor_data_collection_rule_association.rule]
}

# ------------------------------------------------------------------------------------------------ Managed Grafana

resource "azurerm_dashboard_grafana" "grafana" {
  count                 = var.enable_monitoring ? 1 : 0
  name                  = "${local.name}-grafana"
  resource_group_name   = azurerm_resource_group.rso.name
  location              = var.grafana_location
  grafana_major_version = var.grafana_major_version
  sku                   = "Standard"

  # Public endpoint, sign-in with Entra ID (Grafana roles below).
  public_network_access_enabled = true

  identity {
    type = "SystemAssigned"
  }

  # Adds the workspace as a Prometheus data source and gives Grafana's identity read access to it.
  azure_monitor_workspace_integrations {
    resource_id = azurerm_monitor_workspace.prometheus[0].id
  }
}

# Grafana's own identity reads the Prometheus data (and the subscription, for the Azure Monitor data source).
resource "azurerm_role_assignment" "grafana_prometheus_reader" {
  count                = var.enable_monitoring ? 1 : 0
  scope                = azurerm_monitor_workspace.prometheus[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}

resource "azurerm_role_assignment" "grafana_subscription_reader" {
  count                = var.enable_monitoring ? 1 : 0
  scope                = azurerm_resource_group.rso.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}

# Whoever runs terraform can sign in as a Grafana admin; add more people with the Grafana Admin/Editor/Viewer roles.
resource "azurerm_role_assignment" "me_grafana_admin" {
  count                = var.enable_monitoring ? 1 : 0
  scope                = azurerm_dashboard_grafana.grafana[0].id
  role_definition_name = "Grafana Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}
