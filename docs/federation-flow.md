# Workload Identity Federation Flow

End-to-end walkthrough of how Workload Identity Federation (WIF) actually works on the wire, for the two upstream identity sources this module supports: GitHub Actions (true OIDC) and AWS account federation (signed STS verification). The setup infrastructure is the same — pool, provider, service-account binding — but the request shape and what GCP verifies at runtime differs between the two.

If you're looking for *how to configure* the module, see the [main README](../README.md). This doc is about *what happens at runtime* once it's configured.

## Why federation exists

The pre-WIF model: create a GCP service account, generate a JSON key, ship that key to wherever the workload runs (env var, secret store, copied into a container image). The workload signs requests as the SA using the key.

That works, but every key is:

- **Long-lived.** Valid until you rotate or revoke it.
- **Bearer-shaped.** Whoever holds the file *is* the SA. No further proof needed.
- **Hard to audit.** You don't always know where the file ended up — committed to git, cached in CI, copied to a laptop, posted to a Slack thread.

WIF replaces this with short-lived federated tokens. The workload proves its own identity to GCP using whatever identity its host system already gives it (a GitHub OIDC JWT, the AWS task role's STS identity), and GCP mints a service-account access token good for ~1 hour. No long-lived secret travels with the workload, and identity-aware logs show exactly which upstream principal federated.

## The cast

Four entities show up in every flow:

| Role | GitHub example | AWS example |
|---|---|---|
| **Workload** | a workflow job running on a GitHub Actions runner | an ECS task running a container |
| **Upstream identity provider** | GitHub's OIDC issuer at `https://token.actions.githubusercontent.com` | AWS STS (the `GetCallerIdentity` endpoint) |
| **GCP STS** (federation gate) | `sts.googleapis.com` — verifies upstream identity, evaluates `attribute_condition`, checks `principalSet` binding, issues federated token | same |
| **Target service account** | a regular GCP SA like `deployer@my-proj.iam.gserviceaccount.com`, with `roles/iam.workloadIdentityUser` granted to the federated principal | same |

`iamcredentials.googleapis.com` shows up too — it's the service that turns a federated token into a full service-account access token via impersonation (`generateAccessToken`). The JSON produced by `gcloud iam workload-identity-pools create-cred-config` enables this hop automatically.

## Setup vs runtime

Two phases. Setup happens once at provisioning; the runtime exchange happens on every token refresh (roughly hourly).

### Setup (this module / these scripts)

1. **Create a workload identity pool** — a namespace for federated principals.
2. **Create a provider inside the pool.** Type is either:
   - `oidc` (GitHub) — trusts JWTs issued by `https://token.actions.githubusercontent.com`.
   - `aws` (AWS) — trusts callers from a specific AWS account ID, verified via signed STS requests.
3. **Attach `attribute_condition`** — a CEL expression GCP evaluates against the upstream assertion. Your coarse trust filter (e.g. `assertion.repository_owner == 'my-org'`, `assertion.account == '123456789012'`).
4. **Attach `attribute_mapping`** — how to translate upstream claims into Google-side attributes (`google.subject`, `attribute.<name>`). These are the names you reference in conditions and principalSets.
5. **Grant `roles/iam.workloadIdentityUser`** on each target SA to a `principalSet://...` member. This is the precise gate: which federated identities can impersonate which SAs.

After setup, GCP knows: who to trust, what to check, and which SAs each trusted identity can become.

### Runtime (per request)

The exchange runs on every call to a Google API — or rather, the client library caches the resulting access token for its lifetime (~1 hour) and refreshes by re-running the flow. The application code is oblivious; it just makes a normal Google API call.

## GitHub Actions flow

```
Workflow job          GitHub OIDC issuer       GCP STS                 iamcredentials       Google API
     |                       |                    |                         |                    |
  1. Request OIDC token      |                    |                         |                    |
     -----------------------> Mint JWT signed     |                         |                    |
                              by GitHub's key     |                         |                    |
     <-----------------------                     |                         |                    |
  2. Exchange JWT for federated token             |                         |                    |
     -----------------------------------------------> Verify JWT sig        |                    |
                                                      against JWKS          |                    |
                                                  3. Eval attribute_cond    |                    |
                                                  4. Check principalSet     |                    |
                                                  5. Return federated tok   |                    |
     <-----------------------------------------------                       |                    |
  6. Impersonate SA via generateAccessToken                                  |                    |
     ----------------------------------------------------------------------->                    |
                                                                       7. Return SA access tok   |
     <-----------------------------------------------------------------------                    |
  8. Call Google API with SA access token                                                        |
     --------------------------------------------------------------------------------------------->
                                                                                            9. Serve response
     <--------------------------------------------------------------------------------------------
```

### Step-by-step

1. **Request OIDC token from GitHub.** The workflow declares `permissions: id-token: write`, and the `google-github-actions/auth@v2` step calls GitHub's internal `ACTIONS_ID_TOKEN_REQUEST_URL` endpoint to request a JWT, scoped to a specific audience (defaults to the provider's resource URI).
2. **GitHub mints the JWT** signed with its RSA key. The JWT's claims include `sub`, `repository`, `repository_owner`, `ref`, `actor`, `workflow`, `environment`, `job_workflow_ref`, etc. — everything we use for conditions and bindings.
3. **GCP verifies the JWT signature** against GitHub's JWKS (`https://token.actions.githubusercontent.com/.well-known/openid-configuration`).
4. **GCP evaluates `attribute_condition`.** Examples: `assertion.repository_owner == 'my-org'`, `assertion.ref == 'refs/heads/main'`. If false, the exchange is rejected here — no binding is consulted.
5. **GCP checks the principalSet bindings.** It applies `attribute_mapping` to derive the Google-side attributes (`attribute.repository`, etc.), then asks "which SA bindings have a principalSet that matches?" If none, rejection. If yes, proceed.
6. **GCP STS returns a short-lived federated token** scoped to the matched SA(s).
7. **Impersonate the SA via iamcredentials.** The auth library calls `iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/<SA>:generateAccessToken`, exchanging the federated token for a real SA access token.
8. **iamcredentials returns the SA's access token** — the bearer token used to call Google APIs.
9. **Workflow calls a Google API** with `Authorization: Bearer <token>`. API serves the response as if the SA itself made the call.

Steps 1–7 are handled by `google-github-actions/auth@v2` transparently. The workflow author supplies `workload_identity_provider` + `service_account` and the rest is automatic.

## AWS flow

AWS doesn't issue OIDC JWTs for IAM principals. Instead, GCP uses a clever workaround: it asks the AWS workload to *sign* a request to AWS's own `sts:GetCallerIdentity` endpoint using the workload's AWS credentials, then forwards that signed request to AWS STS. AWS validates the signature and tells GCP who the caller is. That's how GCP verifies an AWS identity without ever holding AWS credentials itself.

```
ECS task          AWS metadata        GCP STS                AWS STS         iamcredentials     Google API
   |                   |                  |                     |                  |                |
1. App calls Google API                                                                              
   Auth lib loads gcp-credentials.json                                                               
                                                                                                     
2. Lib sees AWS_CONTAINER_CREDENTIALS_RELATIVE_URI,                                                  
   fetches task-role creds                                                                           
   ------------------>                                                                               
3. Returns access key + session                                                                      
   <------------------                                                                               
4. Lib builds a SigV4-signed                                                                         
   sts:GetCallerIdentity request                                                                     
   (does NOT call AWS itself)                                                                        
                                                                                                     
5. Send signed blob to GCP STS                                                                       
   --------------------------------->                                                                
                                  6. Forward signed request                                          
                                     to AWS STS                                                      
                                     ------------------>                                             
                                                    7. Validate sig,                                 
                                                       return ARN + account                          
                                     <------------------                                             
                                  8. Eval attribute_cond,                                            
                                     check principalSet,                                             
                                     return federated tok                                            
   <---------------------------------                                                                
9. Impersonate SA via generateAccessToken                                                            
   ------------------------------------------------------------------->                              
                                                                  10. Return SA access tok          
   <-------------------------------------------------------------------                              
11. Call Google API                                                                                  
   ----------------------------------------------------------------------------------->              
                                                                                       12. Serve     
   <-----------------------------------------------------------------------------------
```

### Step-by-step

1. **App calls a Google API.** The auth library reads `GOOGLE_APPLICATION_CREDENTIALS` to find the `external_account` JSON committed into the container.
2. **Library detects ECS.** It sees `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` in the env (ECS sets this automatically) and knows to use the task-role credential endpoint, even though the JSON nominally references EC2 IMDS.
3. **Library fetches AWS task-role credentials** — a short-lived access key, secret, and session token — from the ECS metadata endpoint at `169.254.170.2`.
4. **Library builds a SigV4-signed `GetCallerIdentity` request.** Crucially, the library does NOT call AWS STS itself. It builds the HTTP request blob, signs it with the task-role credentials, and passes the *signed* request to GCP.
5. **Send signed blob to GCP STS** (`sts.googleapis.com/v1/token`).
6. **GCP forwards the signed request to AWS STS.** This is the trick — GCP uses the workload's own signature to ask AWS "who is this?" without GCP ever needing AWS credentials of its own.
7. **AWS validates the signature** and returns the caller's ARN (`arn:aws:sts::<acct>:assumed-role/<role>/<session>`) and account ID. AWS STS doesn't care that GCP is the one asking — the signature proves the request came from the rightful holder of the credentials.
8. **GCP applies `attribute_mapping`** to derive `assertion.arn`, `assertion.account`, and `attribute.aws_role` (canonicalized — the session-name suffix is stripped). Evaluates `attribute_condition` (e.g. `assertion.account == '123456789012'`). Checks principalSet bindings. Returns federated token.
9. **Library impersonates the SA via iamcredentials** — same as step 6 of the GitHub flow.
10. **iamcredentials returns the SA's access token.**
11. **App's API call** proceeds with the SA's identity.
12. **Google API serves the response.**

Steps 2–10 are entirely inside the Google auth library. Application code just makes a normal Google API call.

## What you actually have to ship

| | GitHub Actions | AWS ECS |
|---|---|---|
| **Per workflow / container** | Two strings in the action's YAML: `workload_identity_provider` and `service_account` | One JSON file (`gcp-credentials.json`) baked into the image, plus `GOOGLE_APPLICATION_CREDENTIALS` env var pointing at it |
| **Are the artifacts secret?** | No. The provider path is a long resource string; the SA email is just a username. | No. The JSON is config — pool/provider audience, SA email, public AWS metadata URLs. No private key, no token. |
| **What proves the identity at runtime?** | A short-lived OIDC JWT minted by GitHub for *this* job, valid a few minutes. | A SigV4 signature over a synthetic AWS STS request, signed by the task role's session credentials. |
| **What does GCP verify?** | JWT signature against GitHub's JWKS. | The signed request via a real call to AWS STS. |
| **Can the artifact be replayed elsewhere?** | The JWT is audience-bound and one-shot. | The JSON can't authenticate by itself — it only works inside an environment that holds the right AWS credentials. |

## How conditions and bindings interact at runtime

Putting the pieces together. At runtime, every federation attempt traverses three checks in order:

```
upstream token --> mapping --> attribute_condition --> principalSet binding --> SA impersonation
                                       |                       |
                                  if false: deny          if no match: deny
```

| Layer | What it checks | Configured via |
|---|---|---|
| `attribute_mapping` | Nothing — just translates claims into named Google attributes | `attribute_mapping` (defaulted from `provider_type`) |
| `attribute_condition` | Coarse pre-filter: is this assertion in scope at all? | `attribute_condition`, or composed from `allowed_*` helpers |
| `principalSet` binding | Precise gate: does this identity have permission to impersonate *this specific SA*? | `service_accounts` list (one binding per entry) |

A request can fail at any of the three layers. The error messages GCP returns differ, which makes them debuggable — see the table below.

## Common failure modes

| Symptom | Most likely cause | Where in the flow |
|---|---|---|
| `PERMISSION_DENIED: The caller does not have permission` (no matching principalSet) | `service_accounts` binding missing or wrong `attribute_value` | Step 4 (github) / step 8 (aws) |
| `Attribute condition was not met` | Upstream claim doesn't match the condition — wrong owner, wrong account, wrong branch | Step 4 (github) / step 8 (aws) |
| `INVALID_ARGUMENT: Invalid token` | JWT expired or audience mismatch (github); SigV4 signature stale or wrong region (aws) | Step 3 (github) / step 6 (aws) |
| ECS task hangs fetching IMDS | Network can't reach `169.254.170.2`. Rare on Fargate; check security group on EC2-backed tasks | Step 3 (aws) |
| `iam.serviceAccounts.getOpenIdToken denied` | Federated principal can exchange a token but not impersonate — typically a missing or mistyped principalSet binding | Step 6 (github) / step 9 (aws) |
| GitHub OIDC request returns 403 | Missing `permissions: id-token: write` in the workflow YAML | Step 1 (github) |
| `Unauthenticated: there was an error verifying the AWS credentials` | Task role session expired or container ran outside ECS | Step 7 (aws) |

## Summary

- The pool + provider are the **trust boundary** — they define which upstream system is allowed to federate at all.
- `attribute_condition` is the **coarse pre-filter** on the upstream assertion (org, branch, account).
- The `principalSet` binding is the **precise gate** from "trusted identity" to "may impersonate this SA."
- GitHub uses a **true OIDC** flow with JWT verification.
- AWS uses a **signed-request** flow where GCP delegates verification back to AWS STS.
- Both produce short-lived (~1 hour) access tokens; no long-lived secret ever leaves GCP's IAM service.
