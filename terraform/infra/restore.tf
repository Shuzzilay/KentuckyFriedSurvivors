resource "aws_iam_role" "restore" {
  name               = "${var.project}-restore"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "restore_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.backup_bucket}/${var.backup_prefix}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.backup_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.backup_prefix}/*"]
    }
  }
}

resource "aws_iam_role_policy" "restore_read" {
  name   = "read-backups"
  role   = aws_iam_role.restore.id
  policy = data.aws_iam_policy_document.restore_read.json
}

resource "aws_ecs_task_definition" "restore" {
  family             = "${var.project}-restore"
  network_mode       = "host"
  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.restore.arn

  requires_compatibilities = ["EC2"]

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  volume {
    name      = "game-data"
    host_path = local.host_data_path
  }

  container_definitions = jsonencode([
    {
      name      = "restore"
      image     = local.backup_image
      essential = true
      memory    = 512

      entryPoint = ["/usr/local/bin/restore.sh"]

      mountPoints = [
        { sourceVolume = "game-data", containerPath = "/zomboid" },
      ]

      environment = [
        { name = "PZ_BACKUP_BUCKET", value = local.backup_bucket },
        { name = "AWS_REGION", value = var.region },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.server.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "restore"
        }
      }
    },
  ])
}
