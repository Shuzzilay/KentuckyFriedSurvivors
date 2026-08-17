locals {
  discord_enabled = var.discord_public_key != ""
}

data "archive_file" "discord" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda/discord"
  output_path = "${path.module}/.terraform/discord-lambda.zip"

  excludes = ["register-commands.mjs", "a2s.test.mjs", "tickrate.test.mjs"]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "discord" {
  count              = local.discord_enabled ? 1 : 0
  name               = "${var.project}-discord"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "discord" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [aws_ecs_service.server.id]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecs:ListContainerInstances"]
    resources = [aws_ecs_cluster.main.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecs:DescribeContainerInstances"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeVolumes",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:DescribeImages"]
    resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.project}-server"]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"]
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

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.region}:${local.account_id}:*"]
  }

  # Reading the server's own log group, which is where the tick counters live.
  # Scoped to that one group rather than the wildcard above, which exists so the
  # Lambda can write its own logs.
  statement {
    effect    = "Allow"
    actions   = ["logs:FilterLogEvents"]
    resources = ["${aws_cloudwatch_log_group.server.arn}:*"]
  }
}

resource "aws_iam_role_policy" "discord" {
  count  = local.discord_enabled ? 1 : 0
  name   = "control-pz-service"
  role   = aws_iam_role.discord[0].id
  policy = data.aws_iam_policy_document.discord.json
}

resource "aws_cloudwatch_log_group" "discord" {
  count             = local.discord_enabled ? 1 : 0
  name              = "/aws/lambda/${var.project}-discord"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "discord" {
  count = local.discord_enabled ? 1 : 0

  function_name = "${var.project}-discord"
  role          = aws_iam_role.discord[0].arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.discord.output_path
  source_code_hash = data.archive_file.discord.output_base64sha256

  timeout     = 10
  memory_size = 256

  environment {
    variables = {
      PZ_CLUSTER           = aws_ecs_cluster.main.name
      PZ_SERVICE           = aws_ecs_service.server.name
      PZ_INSTANCE_TAG_NAME = "${var.project}-server"
      PZ_DATA_VOLUME_ID    = aws_ebs_volume.data.id
      PZ_BACKUP_BUCKET     = local.backup_bucket
      PZ_BACKUP_PREFIX     = var.backup_prefix
      PZ_BACKUP_INTERVAL   = tostring(var.backup_interval)
      PZ_ECR_REPO          = "${var.project}-server"
      PZ_METRIC_NAMESPACE  = var.metric_namespace

      # PZ answers Steam A2S queries on the game port, so server-status can ask
      # the server itself who is connected. The budget covers two round trips
      # per query and must stay well inside Discord's 3s interaction window.
      PZ_QUERY_PORT      = "16261"
      PZ_QUERY_BUDGET_MS = "1500"

      # Tick rate is read back out of the server's own log lines, which stamp a
      # simulation-step counter and a millisecond clock on every entry. 15
      # minutes is long enough to still yield two samples on a quiet server.
      PZ_LOG_GROUP       = aws_cloudwatch_log_group.server.name
      PZ_TICK_WINDOW_MS  = "900000"
      PZ_TICK_NOMINAL_HZ = "10"

      PZ_MOD_CATALOGUE = jsonencode([
        for m in local.mods : {
          workshop_id = tostring(m.workshop_id)
          name        = try(m.name, "")
          mod_ids     = m.mod_ids
        }
      ])
      DISCORD_PUBLIC_KEY    = var.discord_public_key
      DISCORD_GUILD_ID      = var.discord_guild_id
      DISCORD_CHANNEL_ID    = var.discord_channel_id
      DISCORD_ADMIN_ROLE_ID = var.discord_admin_role_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord]
}

resource "aws_apigatewayv2_api" "discord" {
  count         = local.discord_enabled ? 1 : 0
  name          = "${var.project}-discord"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "discord" {
  count                  = local.discord_enabled ? 1 : 0
  api_id                 = aws_apigatewayv2_api.discord[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.discord[0].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "discord" {
  count     = local.discord_enabled ? 1 : 0
  api_id    = aws_apigatewayv2_api.discord[0].id
  route_key = "POST /interactions"
  target    = "integrations/${aws_apigatewayv2_integration.discord[0].id}"
}

resource "aws_apigatewayv2_stage" "discord" {
  count       = local.discord_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.discord[0].id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "discord" {
  count         = local.discord_enabled ? 1 : 0
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.discord[0].execution_arn}/*/*"
}

output "discord_interactions_url" {
  description = "Paste this into the Discord application's Interactions Endpoint URL field."
  value = local.discord_enabled ? (
    "${trimsuffix(aws_apigatewayv2_stage.discord[0].invoke_url, "/")}/interactions"
  ) : "(disabled - set discord_public_key to enable)"
}
