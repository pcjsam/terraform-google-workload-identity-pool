variable "allowed_repository_owner" {
  type        = string
  description = "GitHub organization or user that owns the repositories. Required if attribute_condition is not set"
  default     = null
}

variable "allowed_repositories" {
  type        = list(string)
  description = "List of allowed repositories in 'owner/repo' format. If empty and allowed_repository_owner is set, all repos from that owner are allowed"
  default     = []
}

variable "allowed_refs" {
  type        = list(string)
  description = "List of allowed git refs (e.g., 'refs/heads/main', 'refs/tags/v*'). If empty, all refs are allowed"
  default     = []
}

variable "allowed_environments" {
  type        = list(string)
  description = "List of allowed GitHub environments (e.g., 'production', 'staging'). If empty, all environments are allowed"
  default     = []
}

variable "allowed_workflows" {
  type        = list(string)
  description = "List of allowed workflow file paths (e.g., '.github/workflows/deploy.yml'). If empty, all workflows are allowed"
  default     = []
}

variable "attribute_condition" {
  type        = string
  description = "Custom CEL expression for attribute condition. If set, this overrides all other condition variables"
  default     = null
}

variable "project_id" {
  type        = string
  description = "The GCP project ID where the workload identity pool will be created"
}

variable "pool_id" {
  type        = string
  description = "The ID of the workload identity pool. Must be 4-32 characters, lowercase letters, digits, and hyphens only"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.pool_id))
    error_message = "Pool ID must be 4-32 characters, start with a letter, and contain only lowercase letters, digits, and hyphens"
  }
}

variable "pool_display_name" {
  type        = string
  description = "Display name for the workload identity pool"
  default     = null
}

variable "pool_description" {
  type        = string
  description = "Description for the workload identity pool"
  default     = null
}

variable "pool_disabled" {
  type        = bool
  description = "Whether the workload identity pool is disabled"
  default     = false
}

variable "provider_id" {
  type        = string
  description = "The ID of the workload identity pool provider"
  default     = "github"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{3,31}$", var.provider_id))
    error_message = "Provider ID must be 4-32 characters, start with a letter, and contain only lowercase letters, digits, and hyphens"
  }
}

variable "provider_display_name" {
  type        = string
  description = "Display name for the workload identity pool provider"
  default     = "GitHub Actions"
}

variable "provider_description" {
  type        = string
  description = "Description for the workload identity pool provider"
  default     = null
}

variable "provider_disabled" {
  type        = bool
  description = "Whether the workload identity pool provider is disabled"
  default     = false
}

variable "attribute_mapping" {
  type        = map(string)
  description = "Maps attributes from the OIDC token to Google Cloud attributes"
  default = {
    "google.subject"             = "assertion.sub"
    "attribute.actor"            = "assertion.actor"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.ref_type"         = "assertion.ref_type"
    "attribute.environment"      = "assertion.environment"
    "attribute.workflow"         = "assertion.workflow"
  }
}

variable "issuer_uri" {
  type        = string
  description = "The OIDC issuer URI. Defaults to GitHub Actions token endpoint"
  default     = "https://token.actions.githubusercontent.com"
}

variable "allowed_audiences" {
  type        = list(string)
  description = "List of allowed audiences for the OIDC provider. If empty, defaults to the issuer URI"
  default     = []
}

variable "service_accounts" {
  type = list(object({
    service_account_email = string
    attribute             = optional(string, "repository")
    attribute_value       = optional(string)
  }))
  description = "List of service accounts to grant workload identity user role. Each entry specifies the service account email and optionally the attribute to use for the principal (repository, repository_owner, or a custom attribute)"
  default     = []
}
