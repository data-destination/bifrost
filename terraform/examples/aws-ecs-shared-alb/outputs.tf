output "bifrost_url" {
  description = "Public URL for Bifrost (via the shared ALB)."
  value       = "https://${var.bifrost_hostname}"
}

output "shared_alb_dns_name" {
  description = "DNS name of the shared ALB (point a Route53 CNAME/ALIAS for bifrost_hostname here if one doesn't already exist)."
  value       = data.aws_lb.shared.dns_name
}

output "shared_alb_zone_id" {
  description = "Hosted zone ID of the shared ALB (for a Route53 ALIAS record)."
  value       = data.aws_lb.shared.zone_id
}

output "target_group_arn" {
  description = "ARN of the dedicated Bifrost target group registered with the shared ALB."
  value       = aws_lb_target_group.bifrost.arn
}

output "security_group_id" {
  description = "ID of the dedicated Bifrost ECS security group."
  value       = aws_security_group.bifrost.id
}

output "health_check_url" {
  description = "Bifrost health check endpoint, routed via the shared ALB host rule."
  value       = "https://${var.bifrost_hostname}/health"
}
