variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for all Bifrost resource names."
  type        = string
  default     = "bifrost"
}

variable "tags" {
  description = "Tags applied to all resources created by this example."
  type        = map(string)
  default = {
    Project = "bifrost"
  }
}

# --- Shared ALB ---

variable "shared_alb_name" {
  description = "Name of the existing shared Application Load Balancer to attach Bifrost to."
  type        = string
  default     = "datadestination-shared-alb"
}

variable "bifrost_hostname" {
  description = "Hostname routed to Bifrost via the shared ALB's HTTPS listener (must be covered by the ALB's ACM certificate)."
  type        = string
  default     = "bifrost.internjobs.io"
}

variable "listener_rule_priority" {
  description = "Priority for the new listener rule on the shared ALB. Must not collide with existing rules on that listener."
  type        = number
  default     = 500
}

variable "hosted_zone_name" {
  description = "Route53 public hosted zone that owns bifrost_hostname."
  type        = string
  default     = "internjobs.io"
}

variable "create_dns_record" {
  description = "Create a Route53 ALIAS record for bifrost_hostname pointing at the shared ALB. Set to false if the record already exists or you manage DNS elsewhere."
  type        = bool
  default     = true
}

# --- Image ---

variable "image_repository" {
  description = "Bifrost OSS Docker image repository."
  type        = string
  default     = "maximhq/bifrost"
}

variable "image_tag" {
  description = "Bifrost OSS Docker image tag (maximhq/bifrost)."
  type        = string
  default     = "v2.6.0"
}

# --- Bifrost config ---

variable "auth_config" {
  description = "Bifrost auth configuration (admin_username, admin_password, is_enabled)."
  type        = any
  default     = null
  sensitive   = true
}

variable "config_store" {
  description = "Config store configuration (defaults to SQLite)."
  type        = any
  default = {
    enabled = true
    type    = "sqlite"
    config = {
      path = "/app/data/bifrost.db"
    }
  }
}

variable "logs_store" {
  description = "Logs store configuration (defaults to SQLite)."
  type        = any
  default = {
    enabled = true
    type    = "sqlite"
    config = {
      path = "/app/data/bifrost-logs.db"
    }
  }
}

variable "providers_config" {
  description = "LLM provider configurations (openai, anthropic, bedrock, etc.). NOTE: this example uses use_secrets_manager = false for simplicity, so this ends up in plaintext in the ECS task definition and in Terraform state. Fine for a learning sandbox you'll destroy — not for production."
  type        = any
  default     = null
  sensitive   = true
}

# --- Compute ---

variable "container_port" {
  description = "Port the Bifrost container listens on."
  type        = number
  default     = 8080
}

variable "desired_count" {
  description = "Number of ECS tasks."
  type        = number
  default     = 1
}

variable "cpu" {
  description = "CPU units for the Fargate task (256-4096)."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Memory in MB for the Fargate task."
  type        = number
  default     = 1024
}

# --- Autoscaling ---

variable "enable_autoscaling" {
  description = "Enable ECS service autoscaling."
  type        = bool
  default     = false
}

variable "min_capacity" {
  description = "Minimum number of tasks when autoscaling is enabled."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of tasks when autoscaling is enabled."
  type        = number
  default     = 3
}
