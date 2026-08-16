
output "server_ip_lookup" {
  description = "How to find the current public IP to give players."
  value       = <<-EOT
    aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=${var.project}-server" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].PublicIpAddress' --output text
  EOT
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "data_volume_id" {
  description = "The world lives here. Snapshot this before anything risky."
  value       = aws_ebs_volume.data.id
}

output "log_group" {
  value = aws_cloudwatch_log_group.server.name
}

output "console_command" {
  description = "Run a server console command via ECS Exec. Output appears in CloudWatch Logs, not in your terminal."
  value       = <<-EOT
    aws ecs execute-command --cluster ${aws_ecs_cluster.main.name} \
      --task <task-id> --container pz --interactive \
      --command "pz-console players"
  EOT
}
