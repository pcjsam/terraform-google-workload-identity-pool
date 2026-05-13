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

## Protocols at a glance

WIF sits at the intersection of three identity-and-access protocols. You don't have to be an expert in any of them, but knowing what each one is for makes the rest of this doc easier to read.

### OAuth 2.0

The umbrella *authorization* framework (RFC 6749). Defines how a client obtains an **access token** scoped to specific resources without ever seeing the user's password or long-lived credentials. OAuth 2.0 says nothing about *who* the client is — it just hands out tokens.

WIF is built on a specific OAuth 2.0 extension called **Token Exchange** (RFC 8693): the client presents one token, and the server hands back another (with potentially different scope, audience, or subject). The federated GCP access tokens you end up with at the end of this flow are plain OAuth 2.0 bearer tokens.

### OpenID Connect (OIDC)

An *identity layer* on top of OAuth 2.0. Adds the concept of an **ID token** — a JWT that asserts *who the caller is*, with standard claims like `sub`, `iss`, `aud`, `exp`. GitHub Actions uses OIDC: when a workflow asks for an identity token, GitHub mints a JWT with claims like `repository`, `ref`, `actor`. GCP can validate that JWT and trust the claims because they're signed by GitHub's well-known key.

If you've ever clicked "Sign in with Google" on a third-party site, that's OIDC under the hood.

### SAML 2.0

A much older (2005-era) XML-based federated-identity protocol, mostly used for enterprise SSO. Same basic idea as OIDC — the identity provider issues a signed assertion about the user — but the format is XML rather than JSON/JWT, and the dance is heavier. GCP WIF *supports* SAML providers, but this module doesn't expose that surface, and most cloud-to-cloud federation today uses OIDC or AWS-style signed requests instead.

You'll typically encounter SAML only when integrating with a legacy enterprise identity provider (Okta SAML, AD FS, etc.).

### How they fit together here

| Protocol | Role in this module |
|---|---|
| OAuth 2.0 Token Exchange (RFC 8693) | The wire protocol of the call to `sts.googleapis.com/v1/token`. Used by *both* the GitHub path and the AWS path. |
| OIDC | What GitHub uses to mint the JWT the GitHub provider verifies. |
| SAML | Not used by this module. GCP supports it as a provider type, but we don't expose it. |
| AWS SigV4 over `GetCallerIdentity` | What the AWS path uses *instead* of OIDC. Not a standard identity protocol — it's a GCP convention that leverages AWS's existing request-signing as proof of identity. |

Two paths this module supports: **OIDC** (github → JWT → GCP verifies signature against GitHub's keys) and **AWS signed STS** (aws → SigV4 blob → GCP delegates verification back to AWS). Both end in the same kind of federated OAuth 2.0 access token.

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

## How GCP knows what to validate

A natural question: how does GCP STS know what kind of credential to expect, and how does it avoid being tricked? The short answer is that the caller explicitly names which provider they're targeting, and the provider's stored configuration determines the validation strategy.

### The wire-level request

Every federation call hits `sts.googleapis.com/v1/token` with three load-bearing fields:

| Field | Role |
|---|---|
| `audience` | The full provider resource path (`//iam.googleapis.com/projects/.../providers/<id>`). **This is how GCP looks up which provider to use.** |
| `subject_token_type` | Wire format: `...token-type:jwt` for OIDC, `...token-type:aws4_request` for AWS. Tells GCP how to interpret the token bytes. |
| `subject_token` | The actual credential — a JWT (github) or a signed `GetCallerIdentity` request (aws). |

The caller is *explicit* about which provider and which credential type. GCP doesn't sniff. If `audience` doesn't resolve to a real provider, or `subject_token_type` doesn't match the provider's stored type, the request is rejected before any cryptographic check.

### How OIDC (GitHub) is validated

GCP holds: the configured `issuer_uri` (e.g. `https://token.actions.githubusercontent.com`) and the allowed audiences.

1. Fetch GitHub's public keys via `<issuer_uri>/.well-known/openid-configuration` → `jwks_uri`. GCP fetches these *directly* from GitHub over HTTPS; the caller doesn't supply them. Results are cached briefly.
2. Verify the JWT signature against the matching public key. Only GitHub holds the private key, so only GitHub can produce JWTs that verify.
3. Check `iss == issuer_uri`, `aud` is allowed, `exp` is in the future, `nbf` is in the past.

The trust root: "GitHub's public keys are who they say they are." GCP knows because it fetched them over TLS from the well-known endpoint — the same trust mechanism your browser uses for `github.com`.

### How AWS is validated

GCP holds: the configured `aws_account_id`.

1. Take the signed `GetCallerIdentity` blob the caller supplied and forward it to AWS STS. **GCP doesn't validate the SigV4 signature itself — it asks AWS to do that.**
2. AWS validates the signature against the credentials it issued for the calling session and returns either an ARN + account ID (valid) or a 403 (invalid).
3. GCP checks the returned account ID equals the provider's configured `aws_account_id`. If they don't match, reject — even though AWS said the signature was valid.

The trust root: "AWS STS at `sts.<region>.amazonaws.com` is really AWS." Same TLS-over-public-DNS guarantee.

### Why this is hard to spoof

- **The audience pins the provider.** A caller can't trick GCP into using a different validation strategy than the provider was configured for.
- **Signing material comes from the upstream, not the caller.** GCP fetches GitHub's JWKS itself; AWS validation goes to AWS itself.
- **Wrong-type tokens are rejected at type-check.** A JWT sent to an AWS-typed provider, or vice versa, fails before any crypto.
- **Replay is short-circuited.** GitHub JWTs are short-lived (minutes) and audience-bound; SigV4 signatures carry a timestamp AWS validates within ~15 min skew.

### What this means for setup

The upstream system (GitHub, AWS) doesn't need to know about GCP at all. GitHub mints JWTs unconditionally; AWS STS validates signatures unconditionally. All the configuration — issuer URI, account ID, conditions, mappings, bindings — lives on the GCP side. That's why you only ever configure WIF "one side of the bridge."

### But the JWT contains a GCP-specific audience — where does that come from?

Not from GitHub. The `google-github-actions/auth@v2` action is the bridge — it's the only thing in the GitHub-side chain that knows the workflow is going to talk to GCP. The action:

1. Reads `workload_identity_provider` from the workflow YAML.
2. Builds the audience string (`//iam.googleapis.com/<provider resource path>`).
3. Calls GitHub's OIDC endpoint requesting a JWT with that audience.
4. GitHub stamps the audience into the JWT's `aud` claim, signs it, hands it back.
5. The action POSTs the JWT to GCP STS, passing the *same* audience again so GCP knows which provider to look up.
6. Optionally calls `iamcredentials.googleapis.com` to impersonate the SA.
7. Exposes the resulting access token to subsequent workflow steps.

GitHub doesn't validate the audience, doesn't talk to GCP, doesn't pre-register relying parties. It treats the audience as an opaque string.

> **The postal analogy.** GitHub is the post office. The action writes the recipient's address on the envelope (`audience = <gcp provider URI>`). The post office stamps the envelope as authentic — signs the JWT — without inspecting what's inside or knowing who lives at the address. GCP opens the envelope, sees its own address on the outside, and confirms "yes, this was addressed to me, by an authentic post office." The post office doesn't keep a list of approved addresses; it just signs whatever the sender writes.

**The audience appears twice in the flow** — once when requesting the JWT (so GitHub stamps it in), and again in the STS exchange request to GCP (so GCP knows which provider to use). Both must match for the audience check to pass. The action handles both sides; you set the audience exactly once via the workflow YAML.

### The AWS-side equivalent

There's no `google-github-actions/auth@v2` for AWS, but the role exists — the **Google auth libraries** (`google-auth` for Python, `google-auth-library` for Node, etc.) play the same choreographer role inside the running container:

1. Read the `external_account` JSON from `GOOGLE_APPLICATION_CREDENTIALS`. This file is the only place that knows both sides — the GCP audience (provider URI) and the runtime AWS metadata endpoints.
2. Fetch the task role's AWS credentials from ECS metadata.
3. Build a SigV4-signed `GetCallerIdentity` request blob.
4. POST it to GCP STS along with the audience from the JSON.
5. Impersonate the SA via iamcredentials.
6. Cache the resulting access token and re-run when it expires.

AWS itself remains incurious — it just validates SigV4 signatures and reports who the caller is, with no idea that GCP is the consumer.

So: in both flows, there's a **piece of middleware that knows both sides** (the action on GitHub, the auth library on AWS). The upstream identity providers themselves stay blind. That's what makes the configuration one-sided — you set everything up on GCP, and the bridge software handles the cross-cloud plumbing at runtime.

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
