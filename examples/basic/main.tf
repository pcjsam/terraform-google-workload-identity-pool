# Basic Example
# Allows any repository from a specific GitHub organization to authenticate

module "github_oidc" {
  source = "../../"

  project_id               = var.project_id
  pool_id                  = "github-pool"
  pool_display_name        = "GitHub Actions Pool"
  pool_description         = "Workload identity pool for GitHub Actions"
  allowed_repository_owner = var.github_org

  service_accounts = [
    {
      service_account_email = var.service_account_email
      attribute             = "repository_owner"
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

variable "service_account_email" {
  type        = string
  description = "Service account email to grant access to"
}

output "workload_identity_provider" {
  value = module.github_oidc.workload_identity_provider
}
