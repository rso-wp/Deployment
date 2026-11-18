output "app_url" {
  value = "http://${local.base_domain}"
}

output "base_domain" {
  description = "Sites are http://<site>.<tenant>.<base_domain>. Put it in WordpressAsAServiceUi/src/app/core/config.ts too."
  value       = local.base_domain
}

output "stripe_webhook_url" {
  value = "http://${local.base_domain}/stripe/webhooks"
}

output "resource_group" {
  value = azurerm_resource_group.rso.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.provision.name
}

output "grafana_url" {
  description = "Azure Managed Grafana. Sign in with your Entra ID account (you are Grafana Admin). Explore → data source 'Managed_Prometheus_...'."
  value       = var.enable_monitoring ? azurerm_dashboard_grafana.grafana[0].endpoint : "Monitoring is off (enable_monitoring = false)."
}

output "kubectl_credentials" {
  value = "az aks get-credentials -g ${azurerm_resource_group.rso.name} -n ${azurerm_kubernetes_cluster.aks.name}"
}

output "argocd" {
  description = "How to open Argo CD (empty when deploy_repo_url is not set)."
  value = local.argocd_enabled ? join("\n", [
    "kubectl -n argocd port-forward svc/argocd-server 8080:443   # then https://localhost:8080, user: admin",
    "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'   # base64 encoded password",
  ]) : "Argo CD is off: deploy_repo_url is empty."
}

output "logs" {
  description = "Where the central logs are (empty when enable_logging is false)."
  value = var.enable_logging ? join("\n", [
    "Azure portal -> resource group ${azurerm_resource_group.rso.name} -> ${azurerm_log_analytics_workspace.logs[0].name} -> Logs, or ${azurerm_application_insights.logs[0].name} -> Logs",
    "AppTraces | where AppRoleName == \"user-service\" | order by TimeGenerated desc",
  ]) : "Central logging is off (enable_logging = false)."
}
