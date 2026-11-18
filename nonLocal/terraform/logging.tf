# Central logging. The three ASP.NET services export what they write through ILogger to Application Insights (an
# OpenTelemetry exporter, switched on by the APPLICATIONINSIGHTS_CONNECTION_STRING the chart passes them); ProvisionFunction
# does the same through the Functions host (the app setting on the Function App). Application Insights stores the logs in
# a Log Analytics workspace, which you can query in the Azure portal (Logs) and which Azure Managed Grafana reads with its
# Azure Monitor data source (enable_monitoring = true).
#
# Tables in the workspace: AppTraces (log lines), AppExceptions, AppRequests. The role name of a line is the service
# (user-service, payment-service, provisioning-service) or the Function App's name.

resource "azurerm_log_analytics_workspace" "logs" {
  count               = var.enable_logging ? 1 : 0
  name                = "${local.name}-logs"
  resource_group_name = azurerm_resource_group.rso.name
  location            = local.monitoring_location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_cap_gb
}

resource "azurerm_application_insights" "logs" {
  count               = var.enable_logging ? 1 : 0
  name                = "${local.name}-ai"
  resource_group_name = azurerm_resource_group.rso.name
  location            = local.monitoring_location
  workspace_id        = azurerm_log_analytics_workspace.logs[0].id
  application_type    = "web"
}

# The connection string for the three services (the chart reads global.logging.existingSecret, see rso_values).
resource "kubernetes_secret_v1" "logging" {
  count = var.enable_logging ? 1 : 0

  metadata {
    name      = "logging"
    namespace = kubernetes_namespace_v1.ns["rso"].metadata[0].name
  }

  data = {
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.logs[0].connection_string
  }
}

# Grafana's own identity may run queries on the workspace.
resource "azurerm_role_assignment" "grafana_logs_reader" {
  count                = var.enable_logging && var.enable_monitoring ? 1 : 0
  scope                = azurerm_log_analytics_workspace.logs[0].id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_dashboard_grafana.grafana[0].identity[0].principal_id
}
