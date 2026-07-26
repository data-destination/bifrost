output "cluster_name" {
  description = "Name of the ECS cluster."
  value       = local.cluster_name
}

output "service_name" {
  description = "Name of the ECS service."
  value       = aws_ecs_service.bifrost.name
}

output "task_definition_arn" {
  description = "ARN of the ECS task definition."
  value       = aws_ecs_task_definition.bifrost.arn
}

output "alb_dns_name" {
  description = "DNS name of the dedicated Application Load Balancer (null when attached to an existing/shared target group)."
  value       = var.create_load_balancer && var.existing_target_group_arn == null ? aws_lb.bifrost[0].dns_name : null
}

output "service_url" {
  description = "URL to access the Bifrost service. Null when attached to an existing/shared target group — use the shared ALB's domain instead."
  value       = var.create_load_balancer && var.existing_target_group_arn == null ? "http://${aws_lb.bifrost[0].dns_name}" : null
}

output "health_check_url" {
  description = "URL to the Bifrost health check endpoint. Null when attached to an existing/shared target group."
  value       = var.create_load_balancer && var.existing_target_group_arn == null ? "http://${aws_lb.bifrost[0].dns_name}${var.health_check_path}" : null
}
