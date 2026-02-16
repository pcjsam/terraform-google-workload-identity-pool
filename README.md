# Terraform Google Workload Identity Pool

This Terraform module creates a Google Cloud Workload Identity Pool and Provider for OIDC-based authentication, primarily designed for GitHub Actions but configurable for other OIDC providers.

## Features

- Configurable workload identity pool and provider
- Built-in security controls with attribute conditions
- Support for restricting access by:
  - Repository owner (organization)
  - Specific repositories
  - Git refs (branches, tags)
  - GitHub environments
  - Workflow files
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
| pool_display_name | Display name for the pool | `string` | `null` | no |
| pool_description | Description for the pool | `string` | `null` | no |
| pool_disabled | Whether the pool is disabled | `bool` | `false` | no |
| provider_id | The ID of the provider | `string` | `"github"` | no |
| provider_display_name | Display name for the provider | `string` | `"GitHub Actions"` | no |
| provider_description | Description for the provider | `string` | `null` | no |
| provider_disabled | Whether the provider is disabled | `bool` | `false` | no |
| issuer_uri | The OIDC issuer URI | `string` | `"https://token.actions.githubusercontent.com"` | no |
| allowed_audiences | Allowed audiences for OIDC | `list(string)` | `[]` | no |
| attribute_mapping | Attribute mapping from OIDC to GCP | `map(string)` | See variables.tf | no |
| attribute_condition | Custom CEL expression | `string` | `null` | no |
| allowed_repository_owner | GitHub org/user owner | `string` | `null` | no |
| allowed_repositories | List of allowed repos | `list(string)` | `[]` | no |
| allowed_refs | List of allowed git refs | `list(string)` | `[]` | no |
| allowed_environments | List of allowed environments | `list(string)` | `[]` | no |
| allowed_workflows | List of allowed workflow files | `list(string)` | `[]` | no |
| service_accounts | Service accounts to bind | `list(object)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| pool_id | The ID of the workload identity pool |
| pool_name | The full resource name of the pool |
| pool_state | The state of the pool |
| provider_id | The ID of the provider |
| provider_name | The full resource name of the provider |
| provider_state | The state of the provider |
| workload_identity_provider | Provider path for GitHub Actions auth |
| principal_set_repository_owner | Principal set for repo owner |
| principal_set_repository | Map of repo principal sets |
| principal_set_all | Principal set for all identities |
| attribute_condition | The computed attribute condition |
| service_account_bindings | Map of SA bindings created |

## Examples

- [Basic](./examples/basic) - Organization-wide access
- [Single Repository](./examples/single-repo) - Single repository access
- [Multi-Repository](./examples/multi-repo) - Multiple repositories with different service accounts
- [Production Environment](./examples/production-environment) - Branch and environment restrictions
- [Custom Condition](./examples/custom-condition) - Custom CEL expression

## License

Apache 2.0
