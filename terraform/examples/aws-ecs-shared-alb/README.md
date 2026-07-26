# Bifrost on AWS ECS — Shared ALB / Default VPC

Deploys Bifrost (OSS) as an isolated ECS Fargate service that:

- Runs in the account's **default VPC** and **default subnets** (no new VPC/subnets created).
- Uses a **dedicated security group** scoped to allow inbound only from the shared ALB's security group — the literal default SG is never modified, so nothing else in the account is affected.
- Runs in its **own dedicated ECS cluster** (`bifrost-cluster`), isolated from other apps' clusters (e.g. `internship-finder`).
- Attaches to the **existing shared ALB** (`datadestination-shared-alb`) via a new dedicated target group and a new host-header listener rule — no dedicated ALB is created, and no existing target group, listener, or rule is modified.
- Serves on `https://bifrost.internjobs.io`, using the shared ALB's existing ACM certificate (`*.internjobs.io`, already issued — no new cert needed).
- Stores its config (`config.json`) in a new AWS Secrets Manager secret, created by the module.
- Uses SQLite for the config/logs store (single replica — no Postgres needed for this deployment).

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
| Secrets Manager secret | ✅ `bifrost/config` | — |
| IAM roles | ✅ ECS execution role, scoped to this secret + log group | — |
| CloudWatch log group | ✅ `/ecs/bifrost` | — |

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

   `terraform.tfvars` is already covered by the repo's `.gitignore` — do not commit it.

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

   This takes a few minutes (ECS cluster + service + task, target group, listener rule, DNS record, Secrets Manager secret).

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

## Cleanup

```bash
terraform destroy
```

This removes only the resources this example created (ECS cluster/service, target group, listener rule, Route53 record, security group, Secrets Manager secret, IAM roles, log group). The shared ALB, default VPC/subnets, ACM certificate, and all other apps on the shared ALB or other ECS clusters are untouched.

## Notes on scaling and storage

The default config here uses SQLite for `config_store`/`logs_store`, which does not support multiple concurrent nodes safely. `desired_count` and `max_capacity` are set to `1` and autoscaling is disabled by default. If you need multiple replicas or autoscaling, switch to a Postgres-backed `config_store`/`logs_store` first — see [Bifrost's multi-node guide](https://docs.getbifrost.ai/deployment-guides/how-to/multinode).

## Notes on the shared ECS cluster decision

Bifrost runs in its own dedicated ECS cluster (`bifrost-cluster`) rather than joining an existing shared cluster like `internship-finder`. Since all services here use Fargate, there's no CPU/memory contention between clusters (Fargate tasks don't share EC2 instances), so this is purely for operational isolation: independent Container Insights metrics, IAM scoping, and safe teardown without any risk to unrelated services.
