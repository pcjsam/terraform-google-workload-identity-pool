# Workload Identity Setup Scripts

Idempotent `gcloud` scripts for projects that manage GCP manually rather than via Terraform. Two scripts cover both GitHub Actions OIDC and AWS account federation:

- **`setup-wif.sh`** — creates the pool and the provider (run once per upstream trust boundary).
- **`bind-sa.sh`** — binds one service account to a federated principal (run once per service / repo / role).

Both scripts use CLI flags — run either with `--help` for usage and example invocations. Re-running with the same inputs is safe.

## Prereqs

- `gcloud` authenticated against an account with `roles/iam.workloadIdentityPoolAdmin` (or owner) on the target project, plus permission to bind IAM on the target service accounts.
- The target service accounts already exist.

## Workflow

1. **Set up the pool + provider** with `setup-wif.sh`. Trust is coarse here — the whole GitHub org (`--github-owner`) or the whole AWS account (`--aws-account-id`). Run once per upstream trust boundary.
2. **Bind a service account** with `bind-sa.sh`. Trust is precise here — a specific repo (`--github-repository`) or a specific AWS role (`--aws-role-name`). Run once per service.

For AWS, `bind-sa.sh` also writes an `external_account` credentials JSON to `--output-file` via `gcloud iam workload-identity-pools create-cred-config`. That file contains no secrets — bake it into the container image and point `GOOGLE_APPLICATION_CREDENTIALS` at it. The Google auth libraries detect ECS via `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` and exchange the task role for a federated GCP token at runtime.

## Flag reference

### `setup-wif.sh`

| Flag | When | Notes |
|---|---|---|
| `--project-id <id>` | always | GCP project ID. |
| `--pool-id <id>` | always | Pool ID. 4-32 chars, lowercase, digits, hyphens; starts with a letter. |
| `--type <github\|aws>` | always | Provider type. |
| `--github-owner <owner>` | `--type=github` | GitHub org/user. |
| `--aws-account-id <id>` | `--type=aws` | 12-digit AWS account ID. |
| `--provider-id <id>` | optional | Defaults to `--type`. |
| `--pool-display-name <name>` | optional | Defaults to `--pool-id`. |
| `--location <loc>` | optional | Default `global`. |
| `-h`, `--help` | | Show help. |

### `bind-sa.sh`

| Flag | When | Notes |
|---|---|---|
| `--project-id <id>` | always | GCP project ID. |
| `--pool-id <id>` | always | Existing pool ID. |
| `--type <github\|aws>` | always | Provider type. |
| `--service-account-email <e>` | always | SA to bind. Must already exist. |
| `--github-repository <r>` | `--type=github` | `owner/repo` (with `--scope repo`) or `owner` (with `--scope owner`). |
| `--aws-account-id <id>` | `--type=aws` | 12-digit AWS account ID. |
| `--aws-role-name <name>` | `--type=aws` | IAM role name the workload assumes. |
| `--scope <repo\|owner>` | optional (github) | Default `repo`. |
| `--output-file <path>` | optional (aws) | Default `./gcp-credentials.json`. |
| `--provider-id <id>` | optional | Defaults to `--type`. |
| `--location <loc>` | optional | Default `global`. |
| `-h`, `--help` | | Show help. |
