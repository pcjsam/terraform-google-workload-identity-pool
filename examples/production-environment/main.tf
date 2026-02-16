# Production Environment Example
# Restricts authentication to production environment and main branch only

module "github_oidc" {
  source = "../../"

  project_id        = var.project_id
  pool_id           = "github-prod-pool"
  pool_display_name = "GitHub Production Pool"
  pool_description  = "Workload identity pool for production deployments only"

  allowed_repositories = ["${var.github_org}/${var.github_repo}"]
  allowed_refs         = ["refs/heads/main"]
  allowed_environments = ["production"]

  service_accounts = [
    {
      service_account_email = var.prod_sa_email
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

variable "prod_sa_email" {
  type        = string
  description = "Production service account email"
}

output "workload_identity_provider" {
  value = module.github_oidc.workload_identity_provider
}

output "attribute_condition" {
  description = "The computed attribute condition showing the security constraints"
  value       = module.github_oidc.attribute_condition
}
