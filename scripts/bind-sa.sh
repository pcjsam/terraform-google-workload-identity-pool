#!/usr/bin/env bash
# Bind a GCP service account so a federated principal (GitHub repo/owner, or
# an AWS assumed-role) can impersonate it. Run setup-wif.sh once for the
# pool+provider, then this once per (service-account, principal) pair.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bind-sa.sh --project-id <id> --pool-id <id> --type <github|aws> \
                  --service-account-email <email> [options]

Binds one GCP service account to a federated principal. For --type=aws, also
writes an external_account credentials JSON via
`gcloud iam workload-identity-pools create-cred-config` for the container to
ship.

Required:
  --project-id <id>              GCP project ID
  --pool-id <id>                 Existing pool ID (from setup-wif.sh)
  --type <github|aws>            Provider type
  --service-account-email <e>    SA to bind (must already exist)

Required for --type=github:
  --github-repository <r>        "owner/repo" (--scope repo) or "owner" (--scope owner)

Required for --type=aws:
  --aws-account-id <id>          12-digit AWS account ID
  --aws-role-name <name>         IAM role name the workload assumes

Optional:
  --provider-id <id>             Existing provider ID (default: same as --type)
  --scope <repo|owner>           github only: bind by repo (default) or whole owner
  --output-file <path>           aws only: where to write credentials JSON
                                 (default: ./gcp-credentials.json)
  --location <loc>               Pool location (default: global)
  -h, --help                     Show this help

Example (github):
  bind-sa.sh --project-id my-proj --pool-id github-pool --type github \
    --github-repository my-org/my-repo \
    --service-account-email deployer@my-proj.iam.gserviceaccount.com

Example (aws):
  bind-sa.sh --project-id my-proj --pool-id aws-ecs-pool --type aws \
    --aws-account-id 123456789012 --aws-role-name community-api-task-role \
    --service-account-email backend-firebase@my-proj.iam.gserviceaccount.com \
    --output-file ./community_api_files/deploy_configuration_files/gcp-credentials.json
EOF
}

PROJECT_ID=""
POOL_ID=""
TYPE=""
SERVICE_ACCOUNT_EMAIL=""
PROVIDER_ID=""
LOCATION="global"
GITHUB_REPOSITORY=""
SCOPE=""
AWS_ACCOUNT_ID=""
AWS_ROLE_NAME=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)            PROJECT_ID="$2"; shift 2 ;;
    --pool-id)               POOL_ID="$2"; shift 2 ;;
    --type)                  TYPE="$2"; shift 2 ;;
    --service-account-email) SERVICE_ACCOUNT_EMAIL="$2"; shift 2 ;;
    --provider-id)           PROVIDER_ID="$2"; shift 2 ;;
    --location)              LOCATION="$2"; shift 2 ;;
    --github-repository)     GITHUB_REPOSITORY="$2"; shift 2 ;;
    --scope)                 SCOPE="$2"; shift 2 ;;
    --aws-account-id)        AWS_ACCOUNT_ID="$2"; shift 2 ;;
    --aws-role-name)         AWS_ROLE_NAME="$2"; shift 2 ;;
    --output-file)           OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)               usage; exit 0 ;;
    *)                       echo "Unknown flag: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

require() { [[ -n "$2" ]] || { echo "$1 is required" >&2; exit 1; }; }

require --project-id            "$PROJECT_ID"
require --pool-id               "$POOL_ID"
require --type                  "$TYPE"
require --service-account-email "$SERVICE_ACCOUNT_EMAIL"

PROVIDER_ID="${PROVIDER_ID:-$TYPE}"

project_number="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
pool_resource="projects/${project_number}/locations/${LOCATION}/workloadIdentityPools/${POOL_ID}"
provider_resource="${pool_resource}/providers/${PROVIDER_ID}"

echo "==> Verifying pool '${POOL_ID}' and provider '${PROVIDER_ID}' exist"
gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location="$LOCATION" >/dev/null
gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="$LOCATION" \
  --workload-identity-pool="$POOL_ID" >/dev/null

case "$TYPE" in
  github)
    require --github-repository "$GITHUB_REPOSITORY"
    SCOPE="${SCOPE:-repo}"
    owner="${GITHUB_REPOSITORY%%/*}"
    case "$SCOPE" in
      repo)
        if [[ "$GITHUB_REPOSITORY" != */* ]]; then
          echo "--scope repo requires --github-repository in 'owner/repo' form" >&2
          exit 1
        fi
        member="principalSet://iam.googleapis.com/${pool_resource}/attribute.repository/${GITHUB_REPOSITORY}"
        ;;
      owner)
        member="principalSet://iam.googleapis.com/${pool_resource}/attribute.repository_owner/${owner}"
        ;;
      *)
        echo "--scope must be 'repo' or 'owner'" >&2
        exit 1
        ;;
    esac
    ;;
  aws)
    require --aws-account-id "$AWS_ACCOUNT_ID"
    require --aws-role-name  "$AWS_ROLE_NAME"
    if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
      echo "--aws-account-id must be 12 digits" >&2
      exit 1
    fi
    assumed_role_arn="arn:aws:sts::${AWS_ACCOUNT_ID}:assumed-role/${AWS_ROLE_NAME}"
    member="principalSet://iam.googleapis.com/${pool_resource}/attribute.aws_role/${assumed_role_arn}"
    OUTPUT_FILE="${OUTPUT_FILE:-./gcp-credentials.json}"
    ;;
  *)
    echo "--type must be 'github' or 'aws'" >&2
    exit 1
    ;;
esac

echo "==> Binding ${SERVICE_ACCOUNT_EMAIL} to ${member}"
gcloud iam service-accounts add-iam-policy-binding "$SERVICE_ACCOUNT_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$member" >/dev/null

case "$TYPE" in
  github)
    cat <<EOF

Done.

  service_account:            ${SERVICE_ACCOUNT_EMAIL}
  github principal:           ${member}
  workload_identity_provider: ${provider_resource}

Wire this into google-github-actions/auth@v2:

  - uses: google-github-actions/auth@v2
    with:
      workload_identity_provider: ${provider_resource}
      service_account: ${SERVICE_ACCOUNT_EMAIL}
EOF
    ;;
  aws)
    echo "==> Writing credentials JSON to ${OUTPUT_FILE}"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    gcloud iam workload-identity-pools create-cred-config \
      "$provider_resource" \
      --service-account="$SERVICE_ACCOUNT_EMAIL" \
      --aws \
      --output-file="$OUTPUT_FILE"

    cat <<EOF

Done.

  service_account:   ${SERVICE_ACCOUNT_EMAIL}
  aws_role:          ${assumed_role_arn}
  credentials_file:  ${OUTPUT_FILE}

Commit '${OUTPUT_FILE}' alongside the service's Dockerfile, COPY it into the
image, and set GOOGLE_APPLICATION_CREDENTIALS in the ECS task to that path.
The file contains no secrets.
EOF
    ;;
esac
