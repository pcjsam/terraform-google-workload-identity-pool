# Custom Condition Example
# Demonstrates attribute_condition as the escape hatch when the helper variables
# (allowed_repositories, allowed_refs, ...) can't express what you need.
#
# This condition combines:
#   - AND across attributes (org + workflow)
#   - OR within the ref check (main branch OR a v-prefixed release tag)
#   - Negation (exclude dependabot[bot])
# The OR and the negation are why the helper variables alone aren't enough.

module "github_oidc" {
  source = "../../"

  project_id        = var.project_id
  pool_id           = "github-custom-pool"
  pool_display_name = "GitHub Custom Pool"
  pool_description  = "Workload identity pool with custom attribute condition"

  # Verbatim CEL. Setting this disables the allowed_* helper variables.
  attribute_condition = <<-EOT
    assertion.repository_owner == '${var.github_org}' &&
    (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v')) &&
    assertion.workflow == '.github/workflows/deploy.yml' &&
    assertion.actor != 'dependabot[bot]'
  EOT

  # Override the default mapping to expose claims the defaults don't (job_workflow_ref,
  # run_id, run_attempt). Setting attribute_mapping replaces the whole map, so the github
  # defaults are copied in alongside the new keys.
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
