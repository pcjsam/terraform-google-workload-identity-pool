#!/usr/bin/env bash
# Create (idempotently) a GCP Workload Identity Pool + provider.
#
# Per-service trust (which repo or AWS role can impersonate which SA) is
# layered on with bind-sa.sh after this script.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-wif.sh --project-id <id> --pool-id <id> --type <github|aws> [options]

Creates (idempotently) a GCP Workload Identity Pool + provider. Trust is set
coarse here (the whole GitHub org or the whole AWS account); per-service
scoping is added with bind-sa.sh.

Required:
  --project-id <id>           GCP project ID
  --pool-id <id>              Pool ID (4-32 chars, lowercase, digits, hyphens;
                              starts with a letter)
  --type <github|aws>         Provider type

Required for --type=github:
  --github-owner <owner>      GitHub org/user that owns the repos

Required for --type=aws:
  --aws-account-id <id>       12-digit AWS account ID

Optional:
  --provider-id <id>          Provider ID (default: same as --type)
  --pool-display-name <name>  Display name for the pool (default: --pool-id)
  --location <loc>            Pool location (default: global)
  -h, --help                  Show this help

Example (github):
  setup-wif.sh --project-id my-proj --pool-id github-pool \
    --type github --github-owner my-org

Example (aws):
  setup-wif.sh --project-id my-proj --pool-id aws-ecs-pool \
    --type aws --aws-account-id 123456789012
EOF
}

PROJECT_ID=""
POOL_ID=""
TYPE=""
PROVIDER_ID=""
POOL_DISPLAY_NAME=""
LOCATION="global"
GITHUB_OWNER=""
AWS_ACCOUNT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)        PROJECT_ID="$2"; shift 2 ;;
    --pool-id)           POOL_ID="$2"; shift 2 ;;
    --type)              TYPE="$2"; shift 2 ;;
    --provider-id)       PROVIDER_ID="$2"; shift 2 ;;
    --pool-display-name) POOL_DISPLAY_NAME="$2"; shift 2 ;;
    --location)          LOCATION="$2"; shift 2 ;;
    --github-owner)      GITHUB_OWNER="$2"; shift 2 ;;
    --aws-account-id)    AWS_ACCOUNT_ID="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *)                   echo "Unknown flag: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

require() { [[ -n "$2" ]] || { echo "$1 is required" >&2; exit 1; }; }

require --project-id "$PROJECT_ID"
require --pool-id    "$POOL_ID"
require --type       "$TYPE"

PROVIDER_ID="${PROVIDER_ID:-$TYPE}"
POOL_DISPLAY_NAME="${POOL_DISPLAY_NAME:-$POOL_ID}"

case "$TYPE" in
  github)
    require --github-owner "$GITHUB_OWNER"
    condition="assertion.repository_owner == '${GITHUB_OWNER}'"
    attribute_mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.ref_type=assertion.ref_type,attribute.environment=assertion.environment,attribute.workflow=assertion.workflow"
    ;;
  aws)
    require --aws-account-id "$AWS_ACCOUNT_ID"
    if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
      echo "--aws-account-id must be 12 digits" >&2
      exit 1
    fi
    condition="assertion.account == '${AWS_ACCOUNT_ID}'"
    attribute_mapping="google.subject=assertion.arn,attribute.account=assertion.account,attribute.aws_role=assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
    ;;
  *)
    echo "--type must be 'github' or 'aws'" >&2
    exit 1
    ;;
esac

project_number="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

echo "==> Ensuring pool '${POOL_ID}' exists in project '${PROJECT_ID}'"
if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
      --project="$PROJECT_ID" --location="$LOCATION" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --display-name="$POOL_DISPLAY_NAME"
else
  echo "    already exists, skipping create"
fi

echo "==> Ensuring ${TYPE} provider '${PROVIDER_ID}' exists in pool '${POOL_ID}'"
provider_exists=0
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
      --project="$PROJECT_ID" \
      --location="$LOCATION" \
      --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  provider_exists=1
fi

case "$TYPE" in
  github)
    if [[ "$provider_exists" -eq 0 ]]; then
      gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="$LOCATION" \
        --workload-identity-pool="$POOL_ID" \
        --display-name="GitHub Actions" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="$attribute_mapping" \
        --attribute-condition="$condition"
    else
      echo "    already exists, refreshing attribute condition"
      gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="$LOCATION" \
        --workload-identity-pool="$POOL_ID" \
        --attribute-condition="$condition"
    fi
    ;;
  aws)
    if [[ "$provider_exists" -eq 0 ]]; then
      gcloud iam workload-identity-pools providers create-aws "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="$LOCATION" \
        --workload-identity-pool="$POOL_ID" \
        --display-name="AWS Account ${AWS_ACCOUNT_ID}" \
        --account-id="$AWS_ACCOUNT_ID" \
        --attribute-mapping="$attribute_mapping" \
        --attribute-condition="$condition"
    else
      echo "    already exists, refreshing attribute condition"
      gcloud iam workload-identity-pools providers update-aws "$PROVIDER_ID" \
        --project="$PROJECT_ID" \
        --location="$LOCATION" \
        --workload-identity-pool="$POOL_ID" \
        --attribute-condition="$condition"
    fi
    ;;
esac

provider_resource="projects/${project_number}/locations/${LOCATION}/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"

cat <<EOF

Pool + provider ready.

workload_identity_provider:
  ${provider_resource}

Bind service accounts with bind-sa.sh, e.g.:

  # github
  bind-sa.sh --project-id ${PROJECT_ID} --pool-id ${POOL_ID} \\
    --provider-id ${PROVIDER_ID} --type github \\
    --github-repository ${GITHUB_OWNER:-<owner>}/<repo> \\
    --service-account-email <sa>@${PROJECT_ID}.iam.gserviceaccount.com

  # aws
  bind-sa.sh --project-id ${PROJECT_ID} --pool-id ${POOL_ID} \\
    --provider-id ${PROVIDER_ID} --type aws \\
    --aws-account-id ${AWS_ACCOUNT_ID:-<acct>} \\
    --aws-role-name <task-role-name> \\
    --service-account-email <sa>@${PROJECT_ID}.iam.gserviceaccount.com \\
    --output-file ./gcp-credentials.json
EOF
