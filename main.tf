locals {
  owner_condition = var.allowed_repository_owner != null ? "assertion.repository_owner == '${var.allowed_repository_owner}'" : null

  repos_condition = length(var.allowed_repositories) > 0 ? (
    length(var.allowed_repositories) == 1
    ? "assertion.repository == '${var.allowed_repositories[0]}'"
    : "assertion.repository in [${join(", ", [for r in var.allowed_repositories : "'${r}'"])}]"
  ) : null

  refs_condition = length(var.allowed_refs) > 0 ? (
    length(var.allowed_refs) == 1
    ? "assertion.ref == '${var.allowed_refs[0]}'"
    : "assertion.ref in [${join(", ", [for r in var.allowed_refs : "'${r}'"])}]"
  ) : null

  envs_condition = length(var.allowed_environments) > 0 ? (
    length(var.allowed_environments) == 1
    ? "assertion.environment == '${var.allowed_environments[0]}'"
    : "assertion.environment in [${join(", ", [for e in var.allowed_environments : "'${e}'"])}]"
  ) : null

  workflows_condition = length(var.allowed_workflows) > 0 ? (
    length(var.allowed_workflows) == 1
    ? "assertion.workflow == '${var.allowed_workflows[0]}'"
    : "assertion.workflow in [${join(", ", [for w in var.allowed_workflows : "'${w}'"])}]"
  ) : null

  all_conditions = compact([
    local.owner_condition,
    local.repos_condition,
    local.refs_condition,
    local.envs_condition,
    local.workflows_condition,
  ])

  computed_attribute_condition = var.attribute_condition != null ? var.attribute_condition : (
    length(local.all_conditions) > 0
    ? join(" && ", local.all_conditions)
    : null
  )

  project_number = data.google_project.project.number
}

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_iam_workload_identity_pool" "pool" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = var.pool_display_name != null ? var.pool_display_name : var.pool_id
  description               = var.pool_description
  disabled                  = var.pool_disabled
}

resource "google_iam_workload_identity_pool_provider" "provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = var.provider_display_name
  description                        = var.provider_description
  disabled                           = var.provider_disabled
  attribute_condition                = local.computed_attribute_condition
  attribute_mapping                  = var.attribute_mapping

  oidc {
    issuer_uri        = var.issuer_uri
    allowed_audiences = length(var.allowed_audiences) > 0 ? var.allowed_audiences : null
  }
}

resource "google_service_account_iam_member" "workload_identity_user" {
  for_each = {
    for idx, sa in var.service_accounts : "${sa.service_account_email}-${idx}" => sa
  }

  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value.service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member = (
    each.value.attribute == "repository_owner"
    ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.repository_owner/${coalesce(each.value.attribute_value, var.allowed_repository_owner)}"
    : each.value.attribute == "repository"
    ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.repository/${coalesce(each.value.attribute_value, try(var.allowed_repositories[0], ""))}"
    : each.value.attribute == "*"
    ? "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/*"
    : "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.pool.name}/attribute.${each.value.attribute}/${each.value.attribute_value}"
  )
}

