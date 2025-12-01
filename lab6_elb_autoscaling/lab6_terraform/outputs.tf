output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.lab6.id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = [for s in aws_subnet.private : s.id]
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.lab6.dns_name
}

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.lab6.name
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = aws_lb_target_group.lab6.arn
}