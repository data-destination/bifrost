# =============================================================================
# Bifrost on AWS ECS — Shared ALB / Default VPC Example
#
# Deploys Bifrost (OSS) as its own ECS Fargate service, in a dedicated ECS
# cluster, using the account's default VPC/subnets, with a dedicated security
# group. Traffic reaches Bifrost through an EXISTING shared Application Load
# Balancer via a new host-header listener rule + dedicated target group.
#
# Nothing here modifies existing target groups, listener rules (other than
# adding one new rule), the default VPC, or other apps' resources.
# =============================================================================

terraform {
  # >= 1.11 required for the S3 backend's use_lockfile (native locking).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # S3-native locking (use_lockfile) — no DynamoDB table required. This is
  # HashiCorp's current recommended approach (GA since Terraform 1.11) and
  # avoids depending on / granting IAM access to a shared lock table.
  backend "s3" {
    bucket       = "terraform-state-576245601309"
    key          = "bifrost/us-east-1/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}

# NOTE: this example calls terraform/modules/bifrost/aws directly instead of
# the multi-cloud terraform/modules/bifrost dispatcher module. The dispatcher
# unconditionally declares azurerm/google provider requirements (even for
# AWS-only deployments, since Terraform resolves provider requirements
# statically across the whole module tree regardless of count=0). Calling
# the AWS submodule directly avoids that entirely — only the aws provider
# is required, no dummy Azure/GCP credentials needed.

locals {
  # Bifrost config.json, built inline (mirrors the merge logic in
  # modules/bifrost/main.tf, scoped to just what this example needs).
  bifrost_config_json = jsonencode({
    "$schema"    = "https://www.getbifrost.ai/schema"
    auth_config  = var.auth_config
    providers    = var.providers_config
    config_store = var.config_store
    logs_store   = var.logs_store
  })
}

# =============================================================================
# Existing shared infrastructure (data sources only — nothing created/modified)
# =============================================================================

# Default VPC
data "aws_vpc" "default" {
  default = true
}

# All default subnets in the default VPC (one per AZ)
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Shared ALB, looked up by name
data "aws_lb" "shared" {
  name = var.shared_alb_name
}

# HTTPS (443) listener on the shared ALB that already has an ACM cert attached
data "aws_lb_listener" "shared_https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

# =============================================================================
# Dedicated security group for the Bifrost ECS task
#
# NOT the default SG — a scoped SG that only allows inbound from the shared
# ALB's security group(s) on the container port, so other resources attached
# to the default SG are completely unaffected.
# =============================================================================

resource "aws_security_group" "bifrost" {
  name        = "${var.name_prefix}-ecs-sg"
  description = "Bifrost ECS task SG - allows inbound only from the shared ALB"
  vpc_id      = data.aws_vpc.default.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ecs-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "from_shared_alb" {
  for_each = toset(data.aws_lb.shared.security_groups)

  security_group_id            = aws_security_group.bifrost.id
  description                  = "Allow inbound from shared ALB SG ${each.value}"
  referenced_security_group_id = each.value
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.bifrost.id
  description       = "Allow all outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}

# =============================================================================
# Dedicated target group for Bifrost, registered with the shared ALB
# =============================================================================

resource "aws_lb_target_group" "bifrost" {
  name        = "${var.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tg"
  })
}

# Additive listener rule on the shared ALB's HTTPS listener — routes
# bifrost.internjobs.io to Bifrost's target group. Does not touch any
# existing rule (100, 150, 175, 200 already in use on this listener).
resource "aws_lb_listener_rule" "bifrost_host" {
  listener_arn = data.aws_lb_listener.shared_https.arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bifrost.arn
  }

  condition {
    host_header {
      values = [var.bifrost_hostname]
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-host-rule"
  })
}

# =============================================================================
# DNS — Route53 ALIAS record for bifrost_hostname pointing at the shared ALB.
# Additive only: does not touch any other record in the hosted zone (jenkins,
# www, internjobs.io apex, MX/TXT/DKIM records, etc.)
# =============================================================================

data "aws_route53_zone" "this" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "bifrost" {
  count = var.create_dns_record ? 1 : 0

  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.bifrost_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# Bifrost deployment — calls the AWS submodule directly (see note above).
# Dedicated ECS cluster, joins the shared ALB via the target group above.
# No dedicated ALB is created (create_load_balancer=false).
#
# use_secrets_manager = false: config.json (including the OpenAI API key) is
# injected as a plaintext environment variable in the task definition instead
# of Secrets Manager. This is simpler and has no Secrets Manager dependency —
# good for learning/sandbox use. It is NOT how you'd do this for a real
# deployment: the config ends up in plaintext in the task definition and in
# Terraform state. For production, set use_secrets_manager = true instead.
# =============================================================================

module "bifrost_aws" {
  source = "../../modules/bifrost/aws"

  service     = "ecs"
  region      = var.region
  name_prefix = var.name_prefix
  tags        = var.tags

  config_json       = local.bifrost_config_json
  image             = "${var.image_repository}:${var.image_tag}"
  container_port    = var.container_port
  health_check_path = "/health"

  use_secrets_manager = false

  # Compute
  desired_count = var.desired_count
  cpu           = var.cpu
  memory        = var.memory

  # Networking — default VPC + default subnets + dedicated SG
  existing_vpc_id             = data.aws_vpc.default.id
  existing_subnet_ids         = data.aws_subnets.default.ids
  existing_security_group_ids = [aws_security_group.bifrost.id]

  # Shared ALB attachment — no dedicated ALB created
  create_load_balancer      = false
  existing_target_group_arn = aws_lb_target_group.bifrost.arn
  assign_public_ip          = true

  # Dedicated ECS cluster (isolated from other apps' clusters)
  create_cluster = true

  # Autoscaling
  enable_autoscaling           = var.enable_autoscaling
  min_capacity                 = var.min_capacity
  max_capacity                 = var.max_capacity
  autoscaling_cpu_threshold    = 80
  autoscaling_memory_threshold = 80

  # K8s-specific params (EKS-only; required by aws/variables.tf with no
  # default even though they're inert for service = "ecs")
  kubernetes_namespace = "unused"
  node_count           = 0
  volume_size_gb       = 10
}
