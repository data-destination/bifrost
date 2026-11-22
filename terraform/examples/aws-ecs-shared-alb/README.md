# Bifrost on AWS ECS — Shared ALB / Default VPC

Deploys Bifrost (OSS) as an isolated ECS Fargate service that:

- Runs in the account's **default VPC** and **default subnets** (no new VPC/subnets created).
- Uses a **dedicated security group** scoped to allow inbound only from the shared ALB's security group — the literal default SG is never modified, so nothing else in the account is affected.
- Runs in its **own dedicated ECS cluster** (`bifrost-cluster`), isolated from other apps' clusters (e.g. `internship-finder`).
- Attaches to the **existing shared ALB** (`datadestination-shared-alb`) via a new dedicated target group and a new host-header listener rule — no dedicated ALB is created, and no existing target group, listener, or rule is modified.
- Serves on `https://bifrost.internjobs.io`, using the shared ALB's existing ACM certificate (`*.internjobs.io`, already issued — no new cert needed).
- Calls the AWS-specific submodule (`terraform/modules/bifrost/aws`) **directly**, instead of the multi-cloud `terraform/modules/bifrost` dispatcher — see [Why this example skips the multi-cloud dispatcher](#why-this-example-skips-the-multi-cloud-dispatcher) below.
- Delivers `config.json` (including provider API keys and the admin password) as a **plaintext environment variable** in the ECS task definition (`use_secrets_manager = false`), not AWS Secrets Manager — see [Security: plaintext config trade-off](#security-plaintext-config-trade-off) below. This is a deliberate simplification for a learning/sandbox deployment, not a production pattern.
- Uses SQLite for the config/logs store (single replica — no Postgres needed for this deployment).

> ⚠️ **This example is a learning sandbox, not a production template.** It intentionally trades security for simplicity (plaintext config instead of Secrets Manager) so a single person can deploy → use → destroy Bifrost on ECS end to end without extra AWS dependencies. Do not reuse `use_secrets_manager = false` for anything that isn't disposable.

## What gets created vs. reused

| Resource | Created | Reused (unmodified) |
|---|---|---|
| VPC / subnets | — | ✅ default VPC + default subnets |
| Security group | ✅ dedicated `bifrost-ecs-sg` | default SG left untouched |
| ECS cluster | ✅ dedicated `bifrost-cluster` | — |
| ECS service/task | ✅ | — |
| Target group | ✅ dedicated, registered with shared ALB | — |
| ALB | — | ✅ `datadestination-shared-alb` (listener 443) |
| Listener rule | ✅ new rule, priority 500, host-header match | existing rules (100/150/175/200) untouched |
| ACM certificate | — | ✅ existing `*.internjobs.io` cert |
| Route53 record | ✅ new `bifrost.internjobs.io` ALIAS | existing records (`jenkins`, `www`, MX/TXT/DKIM, etc.) untouched |
| Secrets Manager secret | — (not used, see below) | — |
| IAM roles | ✅ ECS execution role, scoped to this log group | — |
| CloudWatch log group | ✅ `/ecs/bifrost` | — |

## Why this example skips the multi-cloud dispatcher

`terraform/modules/bifrost` (the root module) is a multi-cloud dispatcher that routes to AWS, GCP, Azure, or generic Kubernetes submodules based on `cloud_provider`/`service`. Terraform resolves **all** provider requirements declared anywhere in a module tree statically, even for submodules with `count = 0` — so the dispatcher unconditionally requires the `azurerm` and `google` providers to be configurable, regardless of which cloud you're actually deploying to.

For an AWS-only deployment, that means `plan`/`apply`/`destroy` would fail (or require dummy Azure/GCP credentials) purely because of a provider requirement you never actually use. This example calls `terraform/modules/bifrost/aws` **directly** instead, which only requires the `aws` provider. If you're deploying to multiple clouds from one root module, use the dispatcher; for a single-cloud AWS deployment like this one, calling the AWS submodule directly avoids the unnecessary dependency entirely.

## Security: plaintext config trade-off

The AWS submodule supports two ways to deliver `config.json` to the running container:

| | `use_secrets_manager = true` (default, secure) | `use_secrets_manager = false` (this example) |
|---|---|---|
| Delivery | AWS Secrets Manager, fetched over the network at container start | Plaintext environment variable baked into the task definition |
| Config visible in | Secrets Manager (access-controlled) | ECS task definition (anyone with `ecs:DescribeTaskDefinition`), Terraform state |
| Extra AWS dependency | Yes (Secrets Manager) | No |
| Cost | ~$0.40/secret/month | $0 |
| Recommended for | Real/production deployments | Learning/sandbox only |

This example uses `use_secrets_manager = false` for simplicity and to avoid a Secrets Manager network dependency while learning the ECS deploy/destroy workflow. **Do not use this setting for anything you're not comfortable treating as fully disposable** — your provider API keys and admin password will be stored in plaintext in:

- The ECS task definition (`aws ecs describe-task-definition --task-definition bifrost-task` shows it in cleartext)
- Terraform state (`bifrost/us-east-1/terraform.tfstate` in the S3 backend)
- Your local `terraform.tfvars`

**Never commit `terraform.tfvars`, plan files (`tfplan`, `*.tfplan`), or any Terraform state to git.** `terraform.tfvars` is covered by `.gitignore`; plan files and state files are also gitignored (`tfplan`, `*.tfplan`, `terraform.tfstate*`) — a Terraform **plan file is a zip archive that embeds the fully resolved state**, so it can leak the same secrets as `terraform.tfvars` even though it doesn't look like a config file. If you ever generate a plan file for review, delete it once you're done — don't leave it sitting in the working directory.

If you rotate to `use_secrets_manager = true` for a longer-lived deployment, set it in your module call and re-apply — the module handles creating the Secrets Manager secret and the IAM permission to read it automatically.

## Prerequisites

- Terraform >= 1.7
- AWS CLI configured with credentials that can manage ECS, EC2 (SG only), ELBv2 (target groups/listener rules), Route53, Secrets Manager, IAM, and CloudWatch Logs.
- Confirmed ahead of time via AWS CLI (see below) — no further discovery needed:
  - Shared ALB: `datadestination-shared-alb`, in the default VPC, with an **HTTPS (443)** listener carrying an ACM cert that covers `*.internjobs.io` (issued and valid).
  - Existing listener rule priorities on that listener: 100, 150, 175, 200 — this deployment uses **500**.
  - No pre-existing `bifrost.internjobs.io` DNS record, no pre-existing Bifrost IAM roles/secrets/log groups/target groups.

## Remote state backend

This example uses an S3 backend with **S3-native locking** (`use_lockfile`), not DynamoDB:

```hcl
backend "s3" {
  bucket       = "terraform-state-576245601309"
  key          = "bifrost/us-east-1/terraform.tfstate"
  region       = "us-east-1"
  use_lockfile = true
  encrypt      = true
}
```

S3-native locking has been GA since Terraform 1.11 and is HashiCorp's current recommended approach — it stores the lock as an object in the same bucket instead of a separate DynamoDB table (the `dynamodb_table` argument is deprecated as of 1.11 and emits a warning). This deployment doesn't provision or depend on any DynamoDB table, which means one fewer resource to manage/secure and no need to grant this project's principals write access to the shared `terraform-state-lock` table used by other projects in this account.

The `bifrost/us-east-1/` key prefix keeps this isolated from other projects' state in the same bucket (e.g. `hello-world/dev/`, `jenkins-infra/dev/`).

**Requires Terraform >= 1.11** for `use_lockfile`. If your Terraform version is older, use the DynamoDB-based locking form instead (`dynamodb_table = "terraform-state-lock"`, no `use_lockfile`).

## Deploy — step by step

1. **Copy and fill in variables:**

   ```bash
   cd terraform/examples/aws-ecs-shared-alb
   cp terraform.tfvars.example terraform.tfvars
   ```

   Edit `terraform.tfvars`:
   - Set `auth_config.admin_password` to a strong password.
   - Add your LLM provider API keys under `providers_config` (OpenAI, Anthropic, etc.).
   - Leave `shared_alb_name`, `bifrost_hostname`, and `listener_rule_priority` as-is unless you want different values.
   - Optionally set `tags` to override the defaults in `variables.tf` (see [Tagging for cost tracking](#tagging-for-cost-tracking) below).

   `terraform.tfvars` is already covered by the repo's `.gitignore` — do not commit it. Remember: with `use_secrets_manager = false` (this example's default), anything you put here — API keys, admin password — ends up in plaintext in the ECS task definition and Terraform state too. See [Security: plaintext config trade-off](#security-plaintext-config-trade-off).

2. **Initialize Terraform** (downloads providers, configures the S3 backend):

   ```bash
   terraform init
   ```

3. **Review the plan.** Confirm it shows only new resources being created (no existing rule/target group/record being modified or destroyed):

   ```bash
   terraform plan -out=tfplan
   ```

   Look for:
   - `+ aws_lb_listener_rule.bifrost_host` (new rule, priority 500) — should **not** show any `~` (in-place change) or `-` (destroy) on other listener rules.
   - `+ aws_route53_record.bifrost` — new record only.
   - `+ aws_security_group.bifrost` — new SG, not a modification of the default SG.

4. **Apply:**

   ```bash
   terraform apply tfplan
   ```

   This takes a few minutes (ECS cluster + service + task, target group, listener rule, DNS record).

5. **Verify the deployment:**

   ```bash
   # Wait for the ECS service to stabilize
   aws ecs wait services-stable --cluster bifrost-cluster --services bifrost-service --region us-east-1

   # Check health via the shared ALB
   curl -sf https://bifrost.internjobs.io/health

   # Check the admin UI is reachable
   curl -sI https://bifrost.internjobs.io
   ```

   If `curl` fails immediately after apply, DNS/target health can take 1-2 minutes to propagate — retry after a short wait. Check target health directly if needed:

   ```bash
   terraform output -raw target_group_arn | xargs -I{} aws elbv2 describe-target-health --target-group-arn {}
   ```

6. **Log in** at `https://bifrost.internjobs.io` with the `admin_username` / `admin_password` you set in `terraform.tfvars`.

## Updating

Change variables in `terraform.tfvars`, then:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

The image tag is pinned (`image_tag`, default `v2.6.0`). `latest` is intentionally not used: Fargate resolves it at task start, so a task restart can silently upgrade the service. To upgrade, change `image_tag` to a released `maximhq/bifrost` tag and apply.

## Cleanup

```bash
terraform destroy
```

This removes only the resources this example created (ECS cluster/service, target group, listener rule, Route53 record, security group, IAM role, log group). The shared ALB, default VPC/subnets, ACM certificate, and all other apps on the shared ALB or other ECS clusters are untouched.

Fargate bills per-second while a task is running, so there is no cost benefit to leaving it deployed between sessions — destroying between uses and re-applying later (state and `terraform.tfvars` persist locally, so nothing is lost) is the cheaper pattern for a stop-start learning workflow. See [Cost](#cost) below for the actual numbers.

## Notes on scaling and storage

The default config here uses SQLite for `config_store`/`logs_store`, which does not support multiple concurrent nodes safely. `desired_count` and `max_capacity` are set to `1` and autoscaling is disabled by default. If you need multiple replicas or autoscaling, switch to a Postgres-backed `config_store`/`logs_store` first — see [Bifrost's multi-node guide](https://docs.getbifrost.ai/deployment-guides/how-to/multinode).

## Notes on the shared ECS cluster decision

Bifrost runs in its own dedicated ECS cluster (`bifrost-cluster`) rather than joining an existing shared cluster like `internship-finder`. Since all services here use Fargate, there's no CPU/memory contention between clusters (Fargate tasks don't share EC2 instances), so this is purely for operational isolation: independent Container Insights metrics, IAM scoping, and safe teardown without any risk to unrelated services.

## Cost

At the default sizing (`cpu = 512` / 0.5 vCPU, `memory = 1024` / 1 GB), Fargate compute in `us-east-1` runs approximately:

| Resource | Rate | Usage | Cost/hr |
|---|---|---|---|
| vCPU | $0.04048/vCPU-hr | 0.5 vCPU | $0.0202 |
| Memory | $0.004445/GB-hr | 1 GB | $0.0044 |
| **Total (Fargate compute)** | | | **~$0.025/hr** (~$18/month if run continuously) |

Everything else this example creates is free or negligible: the ALB listener rule and target group add no charge on top of the already-existing shared ALB, the ECS cluster construct itself is free, CloudWatch log storage/ingestion at this traffic level is effectively $0, and the Route53 record costs nothing beyond the hosted zone's existing monthly charge. This does **not** include any LLM API cost (OpenAI, Anthropic, etc.) — that's billed separately by the provider against your own API key, not through AWS at all. See [Bifrost's own cost tracking](#llm-api-cost-openai-anthropic-etc) below for that side of it.

Since Fargate bills per-second, destroying between sessions (see [Cleanup](#cleanup)) is strictly cheaper than leaving it running — there's no "pause" state that costs less than $0.

## Tagging for cost tracking

All resources in this example are tagged via the `tags` variable (see `variables.tf` for the default, override in `terraform.tfvars`). Example used for this deployment:

```hcl
tags = {
  AppID     = "Bifrost"
  Function  = "Information_Technology"
  Note      = ""
  ManagedBy = "Terraform"
  Developer = "your-email@example.com"
}
```

To make a tag usable for cost breakdowns in AWS Cost Explorer/Budgets, it must be **activated as a cost allocation tag** (a one-time, account-wide setting — not scoped to this app, since it governs how AWS's billing pipeline processes that tag key everywhere it appears):

```bash
aws ce update-cost-allocation-tags-status \
  --cost-allocation-tags-status TagKey=AppID,Status=Active
```

Check activation status:

```bash
aws ce list-cost-allocation-tags --status Active
```

**Two important delays to expect, neither of which indicates misconfiguration:**
- Newly activated tags take up to ~24 hours before Cost Explorer/Budgets reflects any data for them.
- Cost allocation tags are **not retroactive** — only usage that occurs after a tag is activated on a resource gets attributed to it. Usage from before activation, or from a resource that was untagged at the time, will never show up under the tag.
- Cost Explorer's own data pipeline also lags real usage by up to 24 hours, independent of tagging — querying for "today" will typically show `$0`/empty regardless of tags, since today's usage hasn't been billed/processed yet. Query for a fully-elapsed past day instead.

Once tag data has propagated, get this app's cost broken down by AWS service:

```bash
aws ce get-cost-and-usage \
  --time-period Start=2026-07-28,End=2026-07-29 \
  --granularity DAILY \
  --metrics "UnblendedCost" \
  --filter '{"Tags":{"Key":"AppID","Values":["Bifrost"]}}' \
  --group-by Type=DIMENSION,Key=SERVICE
```

This returns a `Total` (single rolled-up figure across every `AppID=Bifrost` resource) and a `Groups` array (broken down by AWS service — e.g. Amazon ECS, CloudWatch). Cost Explorer does not support breaking a tag-filtered total down to the individual resource level (e.g. "this specific target group cost $X") — service/usage-type is the finest granularity available for most resource types. In the console, the equivalent view is **Cost Explorer → Filters → Tag → AppID = Bifrost → Group by: Service**.

To verify tags are actually attached to every resource (independent of Cost Explorer's propagation delay), use the Resource Groups Tagging API, which reflects tags immediately:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=AppID,Values=Bifrost
```

For hands-off monitoring instead of manually re-running Cost Explorer queries, create an [AWS Budget](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html) filtered to the same tag — budgets are free (without automated actions) and update automatically as costs accrue, unlike scripted Cost Explorer API calls which cost $0.01/request:

```bash
aws budgets create-budget --account-id <account-id> --budget '{
  "BudgetName": "Bifrost-AppID-Monthly",
  "BudgetLimit": {"Amount": "10", "Unit": "USD"},
  "BudgetType": "COST",
  "TimeUnit": "MONTHLY",
  "CostFilters": {"TagKeyValue": ["user:AppID$Bifrost"]}
}'
```

## LLM API cost (OpenAI, Anthropic, etc.)

AWS tags and Cost Explorer have no visibility into LLM token spend — that's billed by the provider (e.g. OpenAI) directly against your API key, entirely outside AWS billing. Two ways to track it:

- **Provider's own dashboard** — e.g. [platform.openai.com/usage](https://platform.openai.com/usage), broken down per API key if you use named keys.
- **Bifrost's built-in cost tracking** — Bifrost computes `total_cost` per request from token usage × model pricing, persisted to the configured `logs_store` (SQLite in this example) and viewable in the admin UI's logs/usage pages. Bifrost's governance plugin can also enforce spend **budgets** (not just tracking) per virtual key, team, or customer — see [Bifrost's governance docs](https://docs.getbifrost.ai) if you want a hard cap rather than just visibility.

There is no single dashboard that combines AWS infra cost and LLM token cost — they're two different billers, so tracking "total cost of running Bifrost" means checking both Cost Explorer (AWS infra) and the provider's usage dashboard or Bifrost's own logs (LLM tokens) separately.
