# --- Container ---
variable "image" {
  description = "Full Docker image reference (repository:tag)."
  type        = string
}

variable "container_port" {
  description = "Port the Bifrost container listens on."
  type        = number
}

variable "health_check_path" {
  description = "HTTP path for health checks."
  type        = string
}

# --- Infrastructure ---
variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources."
  type        = map(string)
}

# --- Compute ---
variable "desired_count" {
  description = "Number of ECS tasks."
  type        = number
}

variable "cpu" {
  description = "CPU units for the Fargate task (256-4096)."
  type        = number
}

variable "memory" {
  description = "Memory in MB for the Fargate task."
  type        = number
}

# --- Networking ---
variable "vpc_id" {
  description = "VPC ID for the ECS service."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the ECS service network configuration."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for the ECS service network configuration."
  type        = list(string)
}

# --- IAM & Secrets ---
variable "execution_role_arn" {
  description = "ARN of the ECS task execution IAM role."
  type        = string
}

variable "use_secrets_manager" {
  description = "Deliver config.json via a Secrets Manager secret (secure, recommended for real deployments). When false, config_json is injected as a plaintext environment variable baked into the task definition (simpler, no Secrets Manager cost/dependency, but the config — including any API keys — is stored in plaintext in the task definition and Terraform state)."
  type        = bool
  default     = true
}

variable "secret_arn" {
  description = "ARN of the Secrets Manager secret containing config.json. Required when use_secrets_manager = true."
  type        = string
  default     = null
}

variable "config_json" {
  description = "Complete Bifrost config.json as a string. Required when use_secrets_manager = false (injected as a plaintext environment variable)."
  type        = string
  default     = null
  sensitive   = true
}

variable "log_group_name" {
  description = "CloudWatch log group name."
  type        = string
}

# --- Cluster ---
variable "create_cluster" {
  description = "Create a new ECS cluster. Set to false to use an existing cluster."
  type        = bool
}

# --- Features ---
variable "create_load_balancer" {
  description = "Create a dedicated Application Load Balancer. Ignored when existing_target_group_arn is set."
  type        = bool
}

variable "existing_target_group_arn" {
  description = "ARN of an existing (e.g. shared) ALB target group to register the ECS service with. When set, no dedicated ALB/target group/listener is created — the service attaches to this target group instead."
  type        = string
  default     = null
}

variable "enable_autoscaling" {
  description = "Enable autoscaling for the ECS service."
  type        = bool
}

variable "min_capacity" {
  description = "Minimum number of tasks when autoscaling is enabled."
  type        = number
}

variable "max_capacity" {
  description = "Maximum number of tasks when autoscaling is enabled."
  type        = number
}

variable "autoscaling_cpu_threshold" {
  description = "Target CPU utilization percentage for autoscaling."
  type        = number
}

variable "autoscaling_memory_threshold" {
  description = "Target memory utilization percentage for autoscaling."
  type        = number
}

variable "assign_public_ip" {
  description = "Assign a public IP to the ECS task. Set to false for private subnet deployments."
  type        = bool
  default     = true
}
