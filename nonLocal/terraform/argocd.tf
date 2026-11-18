# Argo CD (GitOps) and Argo CD Image Updater, switched on by deploy_repo_url. Off (empty): nothing here is created and
# helm_release.rso in main.tf installs the platform chart, as before. On: Argo CD installs the chart from the git repository,
# and Image Updater watches Docker Hub and moves each service to the newest tag matching image_version_constraint (a tag
# pushed by the GitHub release workflow of that service). Both start with the cluster, so after `az aks start` whatever
# changed in git or on Docker Hub meanwhile is rolled out. Guide: the Argo CD section of the README.

locals {
  argocd_enabled   = var.deploy_repo_url != ""
  argo_helm_repo   = "https://argoproj.github.io/argo-helm"
  argocd_namespace = "argocd"
}

resource "kubernetes_namespace_v1" "argocd" {
  count = local.argocd_enabled ? 1 : 0
  metadata {
    name = local.argocd_namespace
  }
}

resource "helm_release" "argocd" {
  count      = local.argocd_enabled ? 1 : 0
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd[0].metadata[0].name
  repository = local.argo_helm_repo
  chart      = "argo-cd"
  version    = "10.18.0" # Argo CD v3.6.1
  timeout    = 600

  # One small node: leave out what a single-user setup does not need.
  values = [yamlencode({
    dex            = { enabled = false } # no SSO, you sign in as admin
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }
  })]
}

# Reads the new tags from Docker Hub (public images, no credentials) and changes the Application's image tags. In the same
# namespace as Argo CD and the Application: it only looks at Applications there.
resource "helm_release" "argocd_image_updater" {
  count      = local.argocd_enabled ? 1 : 0
  name       = "argocd-image-updater"
  namespace  = kubernetes_namespace_v1.argocd[0].metadata[0].name
  repository = local.argo_helm_repo
  chart      = "argocd-image-updater"
  version    = "1.4.2"
  timeout    = 600

  depends_on = [helm_release.argocd]
}

# Only for a private deploy repo: how Argo CD signs in to git.
resource "kubernetes_secret_v1" "argocd_repo" {
  count = local.argocd_enabled && var.deploy_repo_password != "" ? 1 : 0

  metadata {
    name      = "rso-deploy-repo"
    namespace = kubernetes_namespace_v1.argocd[0].metadata[0].name
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }

  data = {
    type     = "git"
    url      = var.deploy_repo_url
    username = var.deploy_repo_username
    password = var.deploy_repo_password
  }

  lifecycle {
    precondition {
      condition     = var.deploy_repo_username != ""
      error_message = "deploy_repo_password is set, so deploy_repo_username must be too."
    }
  }
}

# The Application that deploys the rso chart and the Image Updater resource for it (nonLocal/helm/argocd-config). A chart of its own,
# installed after both releases above, so their CRDs exist.
resource "helm_release" "argocd_rso" {
  count     = local.argocd_enabled ? 1 : 0
  name      = "rso-argocd"
  namespace = kubernetes_namespace_v1.argocd[0].metadata[0].name
  chart     = "${path.module}/../helm/argocd-config"

  values = [yamlencode({
    repo = {
      url      = var.deploy_repo_url
      revision = var.deploy_repo_revision
      path     = var.deploy_repo_path
    }
    # The same values Terraform gives its own helm release otherwise. The image tags in them are only the starting point.
    rsoValues         = local.rso_values
    imageRegistry     = var.image_registry
    versionConstraint = var.image_version_constraint
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.argocd_image_updater,
    kubernetes_secret_v1.argocd_repo,
    helm_release.nats,
    helm_release.traefik,
    azurerm_postgresql_flexible_server_database.db,
    azurerm_postgresql_flexible_server_firewall_rule.azure,
    azurerm_storage_queue.q,
  ]
}
