# Custom Condition Example
# Uses a custom CEL expression for advanced filtering

module "github_oidc" {
  source = "../../"

  project_id        = var.project_id
  pool_id           = "github-custom-pool"
  pool_display_name = "GitHub Custom Pool"
  pool_description  = "Workload identity pool with custom attribute condition"

  # Custom CEL expression for complex conditions
  # This example: only allow from specific org, on main branch or release tags,
  # and only from specific workflow
  attribute_condition = <<-EOT
    assertion.repository_owner == '${var.github_org}' &&
    (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v')) &&
    assertion.workflow == '.github/workflows/deploy.yml' &&
    assertion.actor != 'dependabot[bot]'
  EOT

  # Custom attribute mapping to include additional claims
  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.ref_type"         = "assertion.ref_type"
    "attribute.environment"      = "assertion.environment"
    "attribute.workflow"         = "assertion.workflow"
    "attribute.job_workflow_ref" = "assertion.job_workflow_ref"
    "attribute.run_id"           = "assertion.run_id"
    "attribute.run_attempt"      = "assertion.run_attempt"
  }

  service_accounts = [
    {
      service_account_email = var.service_account_email
      attribute             = "repository_owner"
      attribute_value       = var.github_org
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

output "attribute_condition" {
  value = module.github_oidc.attribute_condition
}
