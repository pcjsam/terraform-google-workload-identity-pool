# Single Repository Example
# Restricts authentication to a specific repository

module "github_oidc" {
  source = "../../"

  project_id           = var.project_id
  pool_id              = "github-deploy-pool"
  pool_display_name    = "GitHub Deploy Pool"
  pool_description     = "Workload identity pool for deployment from specific repository"
  allowed_repositories = ["${var.github_org}/${var.github_repo}"]

  service_accounts = [
    {
      service_account_email = var.service_account_email
      attribute             = "repository"
      attribute_value       = "${var.github_org}/${var.github_repo}"
    }
  ]
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "github_org" {
  type        = string
  description = "GitHub organization name"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name"
}

variable "service_account_email" {
  type        = string
  description = "Service account email to grant access to"
}

output "workload_identity_provider" {
  value = module.github_oidc.workload_identity_provider
}

output "principal_set" {
  value = module.github_oidc.principal_set_repository
}
