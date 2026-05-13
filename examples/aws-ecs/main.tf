# AWS ECS Example
# Federates an AWS ECS task role to a GCP service account so the task can call
# Google APIs (e.g. Firebase Admin SDK) without a long-lived service account key.

module "aws_federation" {
  source = "../../"

  project_id     = var.project_id
  pool_id        = "aws-ecs-pool"
  provider_type  = "aws"
  aws_account_id = var.aws_account_id

  allowed_aws_role_arns = [
    "arn:aws:sts::${var.aws_account_id}:assumed-role/${var.ecs_task_role_name}"
  ]

  service_accounts = [
    {
      service_account_email = var.service_account_email
      attribute             = "aws_role"
      attribute_value       = "arn:aws:sts::${var.aws_account_id}:assumed-role/${var.ecs_task_role_name}"
    }
  ]
}

variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID hosting the ECS task"
}

variable "ecs_task_role_name" {
  type        = string
  description = "Name of the ECS task IAM role (the role attached to the task definition)"
}

variable "service_account_email" {
  type        = string
  description = "GCP service account the ECS task will impersonate (e.g. firebase-admin@<project>.iam.gserviceaccount.com)"
}

output "workload_identity_provider" {
  description = "Provider resource path. Use this to build the external_account credentials JSON shipped with the container."
  value       = module.aws_federation.workload_identity_provider
}

output "principal_set_aws_role" {
  description = "Principal set bound to the GCP service account."
  value       = module.aws_federation.principal_set_aws_roles
}
