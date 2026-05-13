# Terraform Google Workload Identity Pool

This Terraform module creates a Google Cloud Workload Identity Pool and Provider for federated authentication. Two provider types are supported:

- **`github`** (default) — GitHub Actions OIDC
- **`aws`** — AWS account federation, e.g. ECS/EKS task roles or EC2 instance profiles calling Google APIs without a long-lived service account key

## Features

- Configurable workload identity pool and provider (GitHub OIDC or AWS account federation)
- Built-in security controls with attribute conditions
- GitHub: restrict by repository owner, repository, git ref, environment, workflow file
- AWS: restrict by AWS account ID and assumed-role ARN
- Service account IAM bindings
- Custom CEL expressions for advanced conditions
- Automatic project number lookup

## Usage

### Basic Usage

```hcl
module "github_oidc" {
  source  = "your-org/workload-identity-pool/google"
  version = "~> 1.0"

  project_id               = "my-project"
  pool_id                  = "github-pool"
  allowed_repository_owner = "my-org"

  service_accounts = [
    {
      service_account_email = "deployer@my-project.iam.gserviceaccount.com"
      attribute             = "repository_owner"
    }
  ]
}
```

### Restrict to Specific Repository

```hcl
module "github_oidc" {
  source  = "your-org/workload-identity-pool/google"
  version = "~> 1.0"

  project_id           = "my-project"
  pool_id              = "github-deploy-pool"
  allowed_repositories = ["my-org/my-repo"]

  service_accounts = [
    {
      service_account_email = "deployer@my-project.iam.gserviceaccount.com"
      attribute             = "repository"
      attribute_value       = "my-org/my-repo"
    }
  ]
}
```

### Production Environment with Branch Restriction

```hcl
module "github_oidc" {
  source  = "your-org/workload-identity-pool/google"
  version = "~> 1.0"

  project_id           = "my-project"
  pool_id              = "github-prod-pool"
  allowed_repositories = ["my-org/my-repo"]
  allowed_refs         = ["refs/heads/main"]
  allowed_environments = ["production"]

  service_accounts = [
    {
      service_account_email = "prod-deployer@my-project.iam.gserviceaccount.com"
      attribute             = "repository"
      attribute_value       = "my-org/my-repo"
    }
  ]
}
```

### AWS Account Federation (e.g. ECS Task Role)

```hcl
module "aws_federation" {
  source  = "your-org/workload-identity-pool/google"
  version = "~> 1.0"

  project_id     = "my-project"
  pool_id        = "aws-ecs-pool"
  provider_type  = "aws"
  aws_account_id = "123456789012"

  allowed_aws_role_arns = [
    "arn:aws:sts::123456789012:assumed-role/my-ecs-task-role"
  ]

  service_accounts = [
    {
      service_account_email = "firebase-admin@my-project.iam.gserviceaccount.com"
      attribute             = "aws_role"
      attribute_value       = "arn:aws:sts::123456789012:assumed-role/my-ecs-task-role"
    }
  ]
}
```

The container then ships an `external_account` credentials JSON pointing at the pool's `workload_identity_provider` output and impersonates the bound service account. No JSON key file is needed.

### Custom Attribute Condition

```hcl
module "github_oidc" {
  source  = "your-org/workload-identity-pool/google"
  version = "~> 1.0"

  project_id = "my-project"
  pool_id    = "github-custom-pool"

  attribute_condition = <<-EOT
    assertion.repository_owner == 'my-org' &&
    assertion.ref == 'refs/heads/main' &&
    assertion.workflow == '.github/workflows/deploy.yml'
  EOT

  service_accounts = [
    {
      service_account_email = "deployer@my-project.iam.gserviceaccount.com"
      attribute             = "repository_owner"
      attribute_value       = "my-org"
    }
  ]
}
```

## Attribute Mapping

The attribute mapping tells GCP how to translate claims from the upstream token (a GitHub Actions JWT or an AWS `GetCallerIdentity` response) into Google-side attributes you can reference in two places:

1. `attribute_condition` — CEL expressions used to allow/deny the token exchange (see [Custom Attribute Condition](#custom-attribute-condition)).
2. `principalSet://` IAM members — what you actually bind to the service account via `roles/iam.workloadIdentityUser`.

Two kinds of keys are valid:

- **`google.subject`** — required; the unique principal identifier. For GitHub it's typically `assertion.sub` (e.g. `repo:my-org/my-repo:ref:refs/heads/main`). For AWS it's typically `assertion.arn`.
- **`attribute.<name>`** — custom attributes you choose to expose. The default mapping defines a handful of useful ones; you can add or rename them.

This module picks a sensible default based on `provider_type`, so most callers can leave `attribute_mapping = null`.

### GitHub default

```hcl
{
  "google.subject"             = "assertion.sub"
  "attribute.actor"            = "assertion.actor"
  "attribute.repository"       = "assertion.repository"
  "attribute.repository_owner" = "assertion.repository_owner"
  "attribute.ref"              = "assertion.ref"
  "attribute.ref_type"         = "assertion.ref_type"
  "attribute.environment"      = "assertion.environment"
  "attribute.workflow"         = "assertion.workflow"
}
```

That's what lets you write `attribute_condition = "assertion.repository == 'my-org/my-repo'"` and bind `principalSet://.../attribute.repository/my-org/my-repo`.

### AWS default

```hcl
{
  "google.subject"     = "assertion.arn"
  "attribute.account"  = "assertion.account"
  "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
}
```

The `attribute.aws_role` expression is the load-bearing one: an assumed-role ARN in an assertion looks like `arn:aws:sts::123:assumed-role/my-role/i-0abc123` (session name suffix included). The CEL above strips the session suffix down to `arn:aws:sts::123:assumed-role/my-role`, so a binding like `principalSet://.../attribute.aws_role/arn:aws:sts::123:assumed-role/my-role` matches every session under that role.

### Overriding

Override only when you need an attribute the default doesn't expose. Example — surface the GitHub org as a separate attribute for use in conditions:

```hcl
attribute_mapping = {
  "google.subject"       = "assertion.sub"
  "attribute.repository" = "assertion.repository"
  "attribute.team"       = "assertion.repository.split('/')[0]"
}
```

When you override, you replace the whole map — the module does not merge with the default. If you still want the default keys, copy them in.

## Service Accounts

Each entry in `service_accounts` creates a `roles/iam.workloadIdentityUser` binding on the named GCP service account, allowing any federated principal whose mapped attribute matches the supplied value to impersonate that SA. Where `attribute_condition` is a coarse pre-filter that decides whether the token exchange is allowed *at all*, this list is the precise gate that says *which SAs* a given identity can become.

Each entry has three fields:

| Field | Required | Notes |
|---|---|---|
| `service_account_email` | yes | The SA being granted to (e.g. `deployer@my-proj.iam.gserviceaccount.com`) |
| `attribute` | no (default `"repository"`) | The mapped attribute the binding's principalSet keys on |
| `attribute_value` | conditional | The value that attribute must equal. Defaults exist for `repository_owner` and `repository` — see below |

The module builds the IAM member as:

```
principalSet://iam.googleapis.com/<pool>/attribute.<attribute>/<attribute_value>
```

Recognized `attribute` values:

- **`repository_owner`** (github) — binds to the whole org. If `attribute_value` is omitted, falls back to `var.allowed_repository_owner`.
- **`repository`** (github) — binds to a single repo. If `attribute_value` is omitted, falls back to the first entry of `var.allowed_repositories`.
- **`aws_role`** (aws) — `attribute_value` is the canonical assumed-role ARN, e.g. `arn:aws:sts::123456789012:assumed-role/my-task-role`. A single binding covers every session under that role because the default `attribute_mapping` strips the session-name suffix.
- **`account`** (aws) — binds to an entire AWS account. Use sparingly; the provider already trusts that account, so this is effectively "any caller in the account."
- **`*`** — binds to every identity in the pool. Use very sparingly.
- Anything else exposed by `attribute_mapping` (e.g. `actor`, `environment`, `workflow`).

### Examples

**GitHub — one repo, one SA:**

```hcl
service_accounts = [
  {
    service_account_email = "deployer@my-proj.iam.gserviceaccount.com"
    attribute             = "repository"
    attribute_value       = "my-org/my-repo"
  },
]
```

**AWS — fan out one pool to several ECS task roles:**

```hcl
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
```

The BE task role can only impersonate the BE SA, the FE task role can only impersonate the FE SA, even though both flow through the same pool and provider.

**Custom attribute — bind to a GitHub environment:**

```hcl
service_accounts = [
  {
    service_account_email = "prod-deployer@my-proj.iam.gserviceaccount.com"
    attribute             = "environment"
    attribute_value       = "production"
  },
]
```

## GitHub Actions Workflow Configuration

After deploying this module, configure your GitHub Actions workflow:

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write  # Required for OIDC

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WORKLOAD_IDENTITY_PROVIDER }}
          service_account: deployer@my-project.iam.gserviceaccount.com

      - uses: google-github-actions/setup-gcloud@v2

      - run: gcloud info
```

Store the `workload_identity_provider` output as a GitHub secret.

## Security Best Practices

1. **Use specific repositories** instead of repository owner when possible
2. **Restrict to specific branches** for production deployments
3. **Use GitHub environments** for additional approval gates
4. **Limit workflow access** to specific workflow files
5. **Avoid wildcard principal sets** in service account bindings

### Attribute Condition Examples

| Scenario | Condition |
|----------|-----------|
| Org only | `assertion.repository_owner == 'my-org'` |
| Single repo | `assertion.repository == 'my-org/my-repo'` |
| Main branch | `assertion.ref == 'refs/heads/main'` |
| Release tags | `assertion.ref.startsWith('refs/tags/v')` |
| Production env | `assertion.environment == 'production'` |
| Specific workflow | `assertion.workflow == '.github/workflows/deploy.yml'` |
| Exclude bot | `assertion.actor != 'dependabot[bot]'` |

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| google | >= 5.0, < 7.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| project_id | The GCP project ID | `string` | n/a | yes |
| pool_id | The ID of the workload identity pool | `string` | n/a | yes |
| provider_type | Provider type: `"github"` or `"aws"` | `string` | `"github"` | no |
| pool_display_name | Display name for the pool | `string` | `null` | no |
| pool_description | Description for the pool | `string` | `null` | no |
| pool_disabled | Whether the pool is disabled | `bool` | `false` | no |
| provider_id | The ID of the provider. If null, defaults to `provider_type` | `string` | `null` | no |
| provider_display_name | Display name for the provider | `string` | `"GitHub Actions"` | no |
| provider_description | Description for the provider | `string` | `null` | no |
| provider_disabled | Whether the provider is disabled | `bool` | `false` | no |
| issuer_uri | The OIDC issuer URI (github only) | `string` | `"https://token.actions.githubusercontent.com"` | no |
| attribute_mapping | Upstream claim → Google attribute translation. See [Attribute Mapping](#attribute-mapping). If null, a default is chosen from `provider_type` | `map(string)` | `null` | no |
| attribute_condition | Custom CEL expression | `string` | `null` | no |
| allowed_repository_owner | GitHub org/user owner | `string` | `null` | no |
| allowed_repositories | List of allowed repos | `list(string)` | `[]` | no |
| allowed_refs | List of allowed git refs | `list(string)` | `[]` | no |
| allowed_environments | List of allowed environments | `list(string)` | `[]` | no |
| allowed_workflows | List of allowed workflow files | `list(string)` | `[]` | no |
| aws_account_id | AWS account the provider trusts. Required when `provider_type = "aws"` | `string` | `null` | conditional |
| allowed_aws_account_ids | List of allowed AWS account IDs | `list(string)` | `[]` | no |
| allowed_aws_role_arns | List of allowed assumed-role ARN prefixes (matched via `startsWith`) | `list(string)` | `[]` | no |
| service_accounts | Service accounts to bind. See [Service Accounts](#service-accounts) | `list(object)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| pool_id | The ID of the workload identity pool |
| pool_name | The full resource name of the pool |
| pool_state | The state of the pool |
| provider_id | The ID of the provider |
| provider_name | The full resource name of the provider |
| provider_state | The state of the provider |
| workload_identity_provider | Provider path for federated auth |
| principal_set_repository_owner | Principal set for repo owner (github) |
| principal_set_repository | Map of repo principal sets (github) |
| principal_set_aws_account | Principal set for the AWS account (aws) |
| principal_set_aws_roles | Map of AWS role ARN to principal set (aws) |
| principal_set_all | Principal set for all identities |
| attribute_condition | The computed attribute condition |
| service_account_bindings | Map of SA bindings created |

## Examples

- [Basic](./examples/basic) - Organization-wide access
- [Single Repository](./examples/single-repo) - Single repository access
- [Multi-Repository](./examples/multi-repo) - Multiple repositories with different service accounts
- [Production Environment](./examples/production-environment) - Branch and environment restrictions
- [Custom Condition](./examples/custom-condition) - Custom CEL expression
- [AWS ECS](./examples/aws-ecs) - ECS task role federated to a GCP service account

## License

Apache 2.0
