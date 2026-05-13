locals {
  is_github = var.provider_type == "github"
  is_aws    = var.provider_type == "aws"

  owner_condition = local.is_github && var.allowed_repository_owner != null ? "assertion.repository_owner == '${var.allowed_repository_owner}'" : null

  repos_condition = local.is_github && length(var.allowed_repositories) > 0 ? (
    length(var.allowed_repositories) == 1
    ? "assertion.repository == '${var.allowed_repositories[0]}'"
    : "assertion.repository in [${join(", ", [for r in var.allowed_repositories : "'${r}'"])}]"
  ) : null

  refs_condition = local.is_github && length(var.allowed_refs) > 0 ? (
    length(var.allowed_refs) == 1
    ? "assertion.ref == '${var.allowed_refs[0]}'"
    : "assertion.ref in [${join(", ", [for r in var.allowed_refs : "'${r}'"])}]"
  ) : null

  envs_condition = local.is_github && length(var.allowed_environments) > 0 ? (
    length(var.allowed_environments) == 1
    ? "assertion.environment == '${var.allowed_environments[0]}'"
    : "assertion.environment in [${join(", ", [for e in var.allowed_environments : "'${e}'"])}]"
  ) : null

  workflows_condition = local.is_github && length(var.allowed_workflows) > 0 ? (
    length(var.allowed_workflows) == 1
    ? "assertion.workflow == '${var.allowed_workflows[0]}'"
    : "assertion.workflow in [${join(", ", [for w in var.allowed_workflows : "'${w}'"])}]"
  ) : null

  aws_accounts_condition = local.is_aws && length(var.allowed_aws_account_ids) > 0 ? (
    length(var.allowed_aws_account_ids) == 1
    ? "assertion.account == '${var.allowed_aws_account_ids[0]}'"
    : "assertion.account in [${join(", ", [for a in var.allowed_aws_account_ids : "'${a}'"])}]"
  ) : null

  aws_roles_condition = local.is_aws && length(var.allowed_aws_role_arns) > 0 ? (
    length(var.allowed_aws_role_arns) == 1
    ? "assertion.arn.startsWith('${var.allowed_aws_role_arns[0]}')"
    : "(${join(" || ", [for r in var.allowed_aws_role_arns : "assertion.arn.startsWith('${r}')"])})"
  ) : null

  all_conditions = compact([
    local.owner_condition,
    local.repos_condition,
    local.refs_condition,
    local.envs_condition,
    local.workflows_condition,
    local.aws_accounts_condition,
    local.aws_roles_condition,
  ])

  computed_attribute_condition = var.attribute_condition != null ? var.attribute_condition : (
    length(local.all_conditions) > 0
    ? join(" && ", local.all_conditions)
    : null
  )

  default_attribute_mapping_github = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.ref_type"         = "assertion.ref_type"
    "attribute.environment"      = "assertion.environment"
    "attribute.workflow"         = "assertion.workflow"
  }

  default_attribute_mapping_aws = {
    "google.subject"     = "assertion.arn"
    "attribute.account"  = "assertion.account"
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }

  computed_attribute_mapping = var.attribute_mapping != null ? var.attribute_mapping : (
    local.is_aws ? local.default_attribute_mapping_aws : local.default_attribute_mapping_github
  )

  resolved_provider_id = coalesce(var.provider_id, var.provider_type)
  project_number       = data.google_project.project.number
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
  workload_identity_pool_provider_id = local.resolved_provider_id
  display_name                       = var.provider_display_name
  description                        = var.provider_description
  disabled                           = var.provider_disabled
  attribute_condition                = local.computed_attribute_condition
  attribute_mapping                  = local.computed_attribute_mapping

  dynamic "oidc" {
    for_each = local.is_github ? [1] : []
    content {
      issuer_uri = var.issuer_uri
    }
  }

  dynamic "aws" {
    for_each = local.is_aws ? [1] : []
    content {
      account_id = var.aws_account_id
    }
  }

  lifecycle {
    precondition {
      condition     = var.provider_type != "aws" || var.aws_account_id != null
      error_message = "aws_account_id must be set when provider_type is 'aws'"
    }
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
