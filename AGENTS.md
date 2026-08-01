# AGENTS.md — terraform-google-workload-identity-pool

## Table of contents

1. [At a glance](#1-at-a-glance)
2. [Domains](#2-domains)
3. [Usage](#3-usage)
4. [Providers](#4-providers)
5. [Conventions](#5-conventions)
6. [Variables](#6-variables)
7. [Outputs](#7-outputs)

---

## 1. At a glance

A **reusable module** that creates a Google Cloud **Workload Identity Pool + Provider** for
keyless federated authentication, plus the service-account bindings that authorize impersonation.
Two upstream identity sources are supported via `provider_type`:

- **`github`** (default) — GitHub Actions OIDC
- **`aws`** — AWS account federation (e.g. ECS/EKS task roles or EC2 instance profiles calling
  Google APIs without a service-account key)

| Thing | Value |
| --- | --- |
| Module type | Reusable module (no submodules, no `examples/`) |
| Terraform | `>= 1.5` |
| Structure | Flat — all resources in `main.tf` |

**This module is never applied from this repo** — it has no backend and is exercised only when a
consuming stack pins a release tag (`?ref=vX.Y.Z`).

**The access-control model in one line:** `attribute_mapping` exposes upstream claims as
attributes → `attribute_condition` is the coarse gate on the token exchange itself → the
`service_accounts` bindings are the precise gate deciding *which* SA a caller may impersonate.
The condition is the door; the binding decides which room you're allowed in once inside.

---

## 2. Domains

### 2.1 Pool & provider

`google_iam_workload_identity_pool` (`pool_id`, ≥4 chars, validated) +
`google_iam_workload_identity_pool_provider` (`provider_id`, defaults to the `provider_type`
string), both in `project_id`, with display-name/description/disabled knobs for each.

- **`github`** → a `dynamic "oidc"` block with `issuer_uri` (defaults to GitHub Actions' token
  endpoint).
- **`aws`** → a `dynamic "aws"` block trusting `aws_account_id` (a `precondition` enforces it is
  set — account-level trust is established here, before any condition runs).
- The provider carries the computed attribute mapping ([§2.2](#22-attribute-mapping)) and
  condition ([§2.3](#23-attribute-condition)).
- A `google_project` data source resolves the project number for the
  `workload_identity_provider` output consumers paste into their auth config.

### 2.2 Attribute mapping

Translates upstream token claims into Google-side attributes referenced by the condition and by
`principalSet://` IAM members. `attribute_mapping = null` (the default) picks per
`provider_type`:

- **github**: `assertion.sub` → `google.subject`, plus `repository`, `repository_owner`, `ref`,
  `ref_type`, `actor`, `environment`, `workflow` as `attribute.<name>`.
- **aws**: `assertion.arn` → `google.subject`, `assertion.account` → `attribute.account`, and a
  derived **`attribute.aws_role`** that strips the session-name suffix from assumed-role ARNs
  (`arn:…:assumed-role/my-role/i-0abc` → `arn:…:assumed-role/my-role`) — this is what lets **one
  binding cover every session under a role**.

Overriding **replaces** the whole map (no merge) — copy the default keys in if you still want
them. `google.subject` is mandatory.

### 2.3 Attribute condition

A CEL expression GCP evaluates at token-exchange time; `false` rejects the exchange before any
binding is consulted. Two ways to set it:

- **Helper variables** (the common path): the module AND's together CEL fragments from whichever
  are set — github: `allowed_repository_owner`, `allowed_repositories`, `allowed_refs`,
  `allowed_environments`, `allowed_workflows`; aws: `allowed_aws_role_arns` (each OR'd via
  `assertion.arn.startsWith(…)`).
- **`attribute_condition` directly** (the escape hatch): if non-null it is used **verbatim and
  the helpers are silently ignored**. Needed for OR across attributes, negation
  (`assertion.actor != 'dependabot[bot]'`), prefix matching, cross-attribute logic, or claims
  the default mapping doesn't expose.

Ready-to-paste CEL patterns:

| Scenario | Condition |
|---|---|
| GitHub org only | `assertion.repository_owner == 'my-org'` |
| One repo | `assertion.repository == 'my-org/my-repo'` |
| Main branch only | `assertion.ref == 'refs/heads/main'` |
| Release tags | `assertion.ref.startsWith('refs/tags/v')` |
| Production env | `assertion.environment == 'production'` |
| Specific workflow | `assertion.workflow == '.github/workflows/deploy.yml'` |
| Exclude bot | `assertion.actor != 'dependabot[bot]'` |
| AWS role (any session) | `assertion.arn.startsWith('arn:aws:sts::123456789012:assumed-role/my-role/')` |
| `main` OR release tag | `assertion.ref == 'refs/heads/main' \|\| assertion.ref.startsWith('refs/tags/v')` |

### 2.4 Service-account bindings

`google_service_account_iam_member` — one `roles/iam.workloadIdentityUser` grant per
`service_accounts` entry, with the member built as
`principalSet://iam.googleapis.com/<pool>/attribute.<attribute>/<attribute_value>`. Recognized
`attribute` values and their defaults:

- `repository_owner` (github) — whole org; `attribute_value` falls back to
  `allowed_repository_owner`.
- `repository` (github, the default) — one repo; falls back to the first
  `allowed_repositories` entry.
- `aws_role` (aws) — one assumed-role ARN; covers every session under it
  ([§2.2](#22-attribute-mapping)).
- `account` (aws) — the whole AWS account; use sparingly (the provider already trusts it, so
  this is "any caller in the account").
- `*` — every identity in the pool; use very sparingly.
- Any other attribute the mapping exposes (`actor`, `environment`, …).

Multiple entries fan one pool out to several SAs with disjoint trust — e.g. a backend ECS task
role that can only impersonate the backend SA and a frontend task role that can only impersonate
the frontend SA, through the same pool.

---

## 3. Usage

GitHub Actions, one repo, one deployer SA:

```hcl
module "github_oidc" {
  source = "github.com/pcjsam/terraform-google-workload-identity-pool?ref=v1.0.0&depth=1"

  project_id           = "my-project"
  pool_id              = "github-deploy-pool"
  allowed_repositories = ["my-org/my-repo"]
  allowed_refs         = ["refs/heads/main"]

  service_accounts = [
    {
      service_account_email = "deployer@my-project.iam.gserviceaccount.com"
      attribute             = "repository"
      attribute_value       = "my-org/my-repo"
    }
  ]
}
```

The consuming workflow then needs `permissions: id-token: write` and:

```yaml
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: ${{ secrets.WORKLOAD_IDENTITY_PROVIDER }}  # the module's output
    service_account: deployer@my-project.iam.gserviceaccount.com
```

AWS federation (ECS task role → GCP SA):

```hcl
module "aws_federation" {
  source = "github.com/pcjsam/terraform-google-workload-identity-pool?ref=v1.0.0&depth=1"

  project_id     = "my-project"
  pool_id        = "aws-ecs-pool"
  provider_type  = "aws"
  aws_account_id = "123456789012"

  allowed_aws_role_arns = ["arn:aws:sts::123456789012:assumed-role/my-ecs-task-role"]

  service_accounts = [
    {
      service_account_email = "firebase-admin@my-project.iam.gserviceaccount.com"
      attribute             = "aws_role"
      attribute_value       = "arn:aws:sts::123456789012:assumed-role/my-ecs-task-role"
    }
  ]
}
```

The container then ships an `external_account` credentials JSON pointing at the
`workload_identity_provider` output (generated with
`gcloud iam workload-identity-pools create-cred-config`); it contains
no secrets — bake it into the image and point `GOOGLE_APPLICATION_CREDENTIALS` at it. The Google
auth libraries detect ECS via `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` and exchange the task role
for a federated GCP token at runtime.

---

## 4. Providers

| Provider | Constraint | Notes |
| --- | --- | --- |
| `hashicorp/google` | `>= 5.0, < 7.0` | The only provider; configuration comes from the caller |

Terraform `required_version` is `>= 1.5`. No backend and no provider blocks are defined here —
both come from the caller.

---

## 5. Conventions

- **44-hash banner sections** in `main.tf`, `variables.tf`, and `outputs.tf`; one banner per
  logical group.
- **Gating by provider type:** provider-specific blocks are `dynamic` on
  `local.is_github` / `local.is_aws`; cross-input requirements are enforced with `precondition`
  (`aws_account_id` when `provider_type = "aws"`) and `validation` blocks (pool/provider ID
  format).
- **CEL composition lives in `locals`** — one fragment per helper variable, `compact`ed and
  AND-joined; the verbatim `attribute_condition` short-circuits all of it.
- The long-form documentation for `attribute_mapping`, `attribute_condition`, and
  `service_accounts` lives in their `variables.tf` heredoc descriptions — keep those authoritative
  and extend them there, not here.
- The only terraform command that runs locally here is `terraform fmt` (no backend, no provider
  config).

---

## 6. Variables

**`variables.tf` is authoritative** — 21 inputs, grouped by banner section, each with
`description` inline (the three
behavior-defining ones carry extensive heredocs). Only the **required** variables (no default —
the caller must supply them) are listed here:

- `project_id`
- `pool_id`
- `aws_account_id` — conditionally: required when `provider_type = "aws"` (enforced by a
  `precondition`)

Everything else is optional with a default.

---

## 7. Outputs

**`outputs.tf` is authoritative** — 14 outputs, each with a `description`: pool/provider
IDs/names/states, **`workload_identity_provider`** (the path consumers paste into
`google-github-actions/auth` or an `external_account` credentials file), ready-made
`principal_set_*` strings (repository owner / per-repo map / AWS account / per-role map / `*`),
the computed `attribute_condition`, and the `service_account_bindings` map.
