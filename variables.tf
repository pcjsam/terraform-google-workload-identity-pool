variable "project_id" {
  type        = string
  description = "The GCP project ID where the workload identity pool will be created"
}

variable "provider_type" {
  type        = string
  description = "OIDC provider type. Supported: 'github' (GitHub Actions OIDC) or 'aws' (AWS account federation, e.g. ECS task roles)"
  default     = "github"
  validation {
    condition     = contains(["github", "aws"], var.provider_type)
    error_message = "provider_type must be 'github' or 'aws'"
  }
}

variable "provider_id" {
  type        = string
  description = "The ID of the workload identity pool provider. If null, defaults to var.provider_type (so 'github' or 'aws'). 4-32 chars, lowercase letters, digits, and hyphens only"
  default     = null
  validation {
    condition     = var.provider_id == null || can(regex("^[a-z][a-z0-9-]{3,31}$", var.provider_id))
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

variable "aws_account_id" {
  type        = string
  description = "AWS account ID that the workload identity provider will trust. Required when provider_type is 'aws'"
  default     = null
}

variable "allowed_aws_account_ids" {
  type        = list(string)
  description = "List of allowed AWS account IDs. Used to scope access when the provider trusts a higher-level identity boundary. If empty, no account-level filter is applied"
  default     = []
}

variable "allowed_aws_role_arns" {
  type        = list(string)
  description = "List of allowed assumed-role ARN prefixes (e.g., 'arn:aws:sts::123456789012:assumed-role/my-task-role'). Each entry is OR'd via assertion.arn.startsWith(...)"
  default     = []
}

variable "attribute_condition" {
  type = string
  description = <<-EOT
    CEL expression evaluated by GCP at token exchange time. Returns false -> exchange rejected
    before any principalSet binding is consulted. Returns true -> request proceeds to the
    per-SA binding check.

    This sits between attribute_mapping (which exposes claims as attributes) and service_accounts
    (which decides which SAs the caller may impersonate). Conditions can express things bindings
    cannot: OR logic, negations, prefix matching, cross-attribute checks.

    If null, the module composes a condition from the helper variables (allowed_repositories,
    allowed_refs, allowed_aws_role_arns, etc.) by AND'ing their CEL fragments. If non-null,
    this string is used verbatim and the helpers are ignored.

    Set this directly when you need:
      - OR across attributes:        assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v')
      - Negation:                    assertion.actor != 'dependabot[bot]'
      - Prefix matching (AWS roles): assertion.arn.startsWith('arn:aws:sts::123:assumed-role/my-role/')
      - Cross-attribute logic:       (assertion.environment == 'production' && assertion.ref == 'refs/heads/main') || assertion.environment == 'staging'
      - Claims not exposed by the default attribute_mapping (e.g. assertion.runner_environment).

    Example:
      attribute_condition = <<-COND
        assertion.repository_owner == 'my-org' &&
        (assertion.ref == 'refs/heads/main' || assertion.ref.startsWith('refs/tags/v')) &&
        assertion.actor != 'dependabot[bot]'
      COND
  EOT
  default = null
}

variable "attribute_mapping" {
  type        = map(string)
  description = <<-EOT
    Translates claims from the upstream token into Google-side attributes that can be referenced
    in attribute_condition (CEL filtering) and principalSet members (IAM bindings). Keys must be
    either 'google.subject' (the unique principal identifier, required) or 'attribute.<name>'
    (custom attributes); values are CEL expressions over the upstream assertion. If null, a
    default is chosen from provider_type:

    - github: maps assertion.sub -> google.subject, plus assertion.repository, repository_owner,
      ref, ref_type, actor, workflow, environment as attribute.<name>. This is what lets you
      bind 'principalSet://.../attribute.repository/my-org/my-repo'.

    - aws: maps assertion.arn -> google.subject, assertion.account -> attribute.account, and
      derives a canonical attribute.aws_role from the assumed-role ARN (stripping the session-
      name suffix). This is what lets you bind
      'principalSet://.../attribute.aws_role/arn:aws:sts::<acct>:assumed-role/<role>'.

    Override only when you need an attribute the default doesn't expose. Example:
      attribute_mapping = {
        "google.subject"       = "assertion.sub"
        "attribute.repository" = "assertion.repository"
        "attribute.team"       = "assertion.repository.split('/')[0]"
      }
  EOT
  default     = null
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

variable "issuer_uri" {
  type        = string
  description = "The OIDC issuer URI. Only used when provider_type is 'github'. Defaults to GitHub Actions token endpoint"
  default     = "https://token.actions.githubusercontent.com"
}

variable "service_accounts" {
  type = list(object({
    service_account_email = string
    attribute             = optional(string, "repository")
    attribute_value       = optional(string)
  }))
  description = <<-EOT
    Service accounts to grant roles/iam.workloadIdentityUser. Each entry creates one IAM binding
    on the named SA, allowing any federated principal whose mapped attribute matches the supplied
    value to impersonate it. This is the precise access-control layer — attribute_condition is a
    coarse pre-filter, this is the gate that actually authorizes impersonation.

    Fields:
      - service_account_email: full SA email (e.g. deployer@my-proj.iam.gserviceaccount.com).
      - attribute:             which mapped attribute the binding's principalSet uses.
      - attribute_value:       the value the attribute must equal. Optional for the two cases
                               noted below.

    The IAM member is constructed as:
      principalSet://iam.googleapis.com/<pool>/attribute.<attribute>/<attribute_value>

    Recognized attribute values:
      - "repository_owner" (github): binds to the whole owner/org. attribute_value defaults to
        var.allowed_repository_owner when omitted.
      - "repository" (github): binds to a single repo. attribute_value defaults to the first
        entry of var.allowed_repositories when omitted.
      - "aws_role" (aws): binds to an assumed-role ARN, e.g.
        "arn:aws:sts::123456789012:assumed-role/my-task-role". One binding covers every session
        under that role (the default attribute_mapping strips the session-name suffix).
      - "account" (aws): binds to an entire AWS account. Use sparingly.
      - "*": binds to every identity in the pool. Use very sparingly.
      - Any other attribute exposed by attribute_mapping (e.g. "actor", "environment").

    Examples:

      # GitHub — bind a deployer SA to one repo
      service_accounts = [
        {
          service_account_email = "deployer@my-proj.iam.gserviceaccount.com"
          attribute             = "repository"
          attribute_value       = "my-org/my-repo"
        },
      ]

      # AWS — bind two SAs to two different ECS task roles in the same pool
      service_accounts = [
        {
          service_account_email = "backend-firebase@my-proj.iam.gserviceaccount.com"
          attribute             = "aws_role"
          attribute_value       = "arn:aws:sts::123456789012:assumed-role/be-task-role"
        },
        {
          service_account_email = "frontend-firebase@my-proj.iam.gserviceaccount.com"
          attribute             = "aws_role"
          attribute_value       = "arn:aws:sts::123456789012:assumed-role/fe-task-role"
        },
      ]
  EOT
  default     = []
}
