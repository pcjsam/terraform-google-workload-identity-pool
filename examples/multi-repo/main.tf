# Multi-Repository Example
# Allows multiple specific repositories with different service accounts

module "github_oidc" {
  source = "../../"

  project_id        = var.project_id
  pool_id           = "github-multi-repo-pool"
  pool_display_name = "GitHub Multi-Repo Pool"
  pool_description  = "Workload identity pool for multiple repositories"

  allowed_repositories = [
    "${var.github_org}/app-frontend",
    "${var.github_org}/app-backend",
    "${var.github_org}/infrastructure",
  ]

  service_accounts = [
    {
      service_account_email = var.frontend_sa_email
      attribute             = "repository"
      attribute_value       = "${var.github_org}/app-frontend"
    },
    {
      service_account_email = var.backend_sa_email
      attribute             = "repository"
      attribute_value       = "${var.github_org}/app-backend"
    },
    {
      service_account_email = var.infra_sa_email
      attribute             = "repository"
      attribute_value       = "${var.github_org}/infrastructure"
    },
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

variable "frontend_sa_email" {
  type        = string
  description = "Frontend service account email"
}

variable "backend_sa_email" {
  type        = string
  description = "Backend service account email"
}

variable "infra_sa_email" {
  type        = string
  description = "Infrastructure service account email"
}

output "workload_identity_provider" {
  value = module.github_oidc.workload_identity_provider
}

output "principal_sets" {
  value = module.github_oidc.principal_set_repository
}
