output "pool_id" {
  description = "The ID of the workload identity pool"
  value       = google_iam_workload_identity_pool.pool.workload_identity_pool_id
}

output "pool_name" {
  description = "The full resource name of the workload identity pool"
  value       = google_iam_workload_identity_pool.pool.name
}

output "pool_state" {
  description = "The state of the workload identity pool"
  value       = google_iam_workload_identity_pool.pool.state
}

output "provider_id" {
  description = "The ID of the workload identity pool provider"
  value       = google_iam_workload_identity_pool_provider.provider.workload_identity_pool_provider_id
}

output "provider_name" {
  description = "The full resource name of the workload identity pool provider"
  value       = google_iam_workload_identity_pool_provider.provider.name
}

output "provider_state" {
  description = "The state of the workload identity pool provider"
  value       = google_iam_workload_identity_pool_provider.provider.state
}

output "workload_identity_provider" {
  description = "The workload identity provider resource path for use in GitHub Actions auth"
  value       = "projects/${local.project_number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.pool.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.provider.workload_identity_pool_provider_id}"
}

output "principal_set_repository_owner" {
  description = "Principal set for repository owner attribute (use in IAM bindings)"
  value       = var.allowed_repository_owner != null ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.repository_owner/${var.allowed_repository_owner}" : null
}

output "principal_set_repository" {
  description = "Principal set for repository attribute (use in IAM bindings). Returns map of repository to principal set"
  value = {
    for repo in var.allowed_repositories : repo => "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.repository/${repo}"
  }
}

output "principal_set_all" {
  description = "Principal set matching all identities in the pool (use with caution)"
  value       = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/*"
}

output "principal_set_aws_account" {
  description = "Principal set for the AWS account attribute (use in IAM bindings). Null when provider_type is not 'aws' or aws_account_id is unset"
  value       = local.is_aws && var.aws_account_id != null ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.account/${var.aws_account_id}" : null
}

output "principal_set_aws_roles" {
  description = "Map of AWS role ARN to principal set for use in IAM bindings"
  value = {
    for role_arn in var.allowed_aws_role_arns : role_arn => "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.aws_role/${role_arn}"
  }
}

output "attribute_condition" {
  description = "The computed attribute condition applied to the provider"
  value       = local.computed_attribute_condition
}

output "service_account_bindings" {
  description = "Map of service account bindings created"
  value = {
    for key, binding in google_service_account_iam_member.workload_identity_user : key => {
      service_account = binding.service_account_id
      member          = binding.member
    }
  }
}
