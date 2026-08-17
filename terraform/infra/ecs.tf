resource "aws_ecs_cluster" "main" {
  name = var.project

  setting {
    name  = "containerInsights"
    value = "disabled" # Avoid per-metric cost.
  }
}

resource "aws_cloudwatch_log_group" "server" {
  name              = "/ecs/${var.project}"
  retention_in_days = var.log_retention_days
}

locals {
  host_data_path = "/mnt/pz-data"
}

resource "aws_ecs_task_definition" "server" {
  family             = var.project
  network_mode       = "host"
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  requires_compatibilities = ["EC2"]

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  volume {
    name      = "game-data"
    host_path = local.host_data_path
  }

  volume {
    name      = "server-install"
    host_path = "${local.host_data_path}/server-install"
  }

  container_definitions = jsonencode([
    {
      name      = "pz"
      image     = local.server_image
      essential = true

      memory = 12288

      stopTimeout = var.task_stop_timeout_seconds

      portMappings = [
        { containerPort = 16261, hostPort = 16261, protocol = "udp" },
        { containerPort = 16262, hostPort = 16262, protocol = "udp" },
      ]

      mountPoints = [
        { sourceVolume = "game-data", containerPath = "/zomboid" },
        { sourceVolume = "server-install", containerPath = "/opt/pzserver" },
      ]

      environment = concat([
        { name = "PZ_SERVER_NAME", value = var.server_name },
        { name = "PZ_MEMORY", value = var.pz_memory },
        { name = "PZ_UPDATE_ON_BOOT", value = tostring(var.update_on_boot) },
        { name = "PZ_SAVE_WAIT", value = "25" },
        { name = "PZ_QUIT_WAIT", value = "60" },
      ], local.pz_config_environment)

      secrets = concat([
        {
          name      = "PZ_ADMIN_PASSWORD"
          valueFrom = "arn:aws:ssm:${var.region}:${local.account_id}:parameter${var.admin_password_parameter}"
        },
      ], local.pz_config_secrets)

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.server.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "pz"
        }
      }
    },
    {
      name      = "backup"
      image     = local.backup_image
      essential = false
      memory    = 512

      mountPoints = [
        { sourceVolume = "game-data", containerPath = "/zomboid" },
      ]

      environment = [
        { name = "PZ_BACKUP_BUCKET", value = local.backup_bucket },
        { name = "PZ_BACKUP_PREFIX", value = var.backup_prefix },
        { name = "PZ_BACKUP_INTERVAL", value = tostring(var.backup_interval) },
        { name = "PZ_BACKUP_SAVE_WAIT", value = "20" },
        { name = "PZ_METRIC_NAMESPACE", value = var.metric_namespace },
        { name = "AWS_REGION", value = var.region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.server.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "backup"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "server" {
  name            = var.project
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.server.arn
  desired_count   = 1
  launch_type     = "EC2"

  enable_execute_command = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  wait_for_steady_state = false

  lifecycle {
    ignore_changes = [desired_count]
  }
}
