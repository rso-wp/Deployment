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

output "argocd_url" {
  description = "The Argo CD web UI. Sign in as admin; the password command is in the argocd output."
  value = !local.argocd_enabled ? "Argo CD is off: deploy_repo_url is empty." : (
    var.expose_argocd_ui ? local.argocd_url : "Not public (expose_argocd_ui = false): run the port-forward command of the argocd output, then open https://localhost:8080"
  )
}

output "argocd" {
  description = "How to sign in to Argo CD (empty when deploy_repo_url is not set)."
  value = local.argocd_enabled ? join("\n", [
    var.expose_argocd_ui ? "UI: ${local.argocd_url}   (plain HTTP)" : "UI: kubectl -n argocd port-forward svc/argocd-server 8080:443   # then https://localhost:8080",
    "user: admin",
    "password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'   # base64 encoded",
  ]) : "Argo CD is off: deploy_repo_url is empty."
}

output "logs" {
  description = "Where the central logs are (empty when enable_logging is false)."
  value = var.enable_logging ? join("\n", [
    "Azure portal -> resource group ${azurerm_resource_group.rso.name} -> ${azurerm_log_analytics_workspace.logs[0].name} -> Logs, or ${azurerm_application_insights.logs[0].name} -> Logs",
    "AppTraces | where AppRoleName == \"user-service\" | order by TimeGenerated desc",
  ]) : "Central logging is off (enable_logging = false)."
}

output "keycloak" {
  description = "Keycloak: sign-up and log-in of the app. Admin console: sign in as admin (master realm)."
  value = join("\n", [
    "login pages: http://${local.keycloak_host}/realms/rso/account",
    "admin console: http://${local.keycloak_host}/admin   user: admin   (over plain http first run the one-time command in the repository README, 'The admin console needs one command')",
    "admin password: terraform output -raw keycloak_admin_password",
  ])
}

output "keycloak_admin_password" {
  description = "Password of the first Keycloak admin (user admin)."
  value       = random_password.keycloak_admin.result
  sensitive   = true
}
