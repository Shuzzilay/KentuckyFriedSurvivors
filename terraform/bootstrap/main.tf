terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.57"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "project-zomboid"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region. Pick one close to your players; latency matters more than price here."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "pz"
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the deploy role, as OWNER/REPO."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub owner ID, required by GitHub's post-2026-07 OIDC subject claim."
  type        = string
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository ID, required by GitHub's post-2026-07 OIDC subject claim."
  type        = string
}

variable "backup_retention_days" {
  description = "Days to keep game-data backups. Short by design: this is a crash fallback, not an archive."
  type        = number
  default     = 5
}

variable "backup_prefix" {
  description = "Key prefix for game-data backups. Must match PZ_BACKUP_PREFIX in the backup sidecar."
  type        = string
  default     = "backups"
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket  = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  backup_bucket = "${var.project}-backups-${data.aws_caller_identity.current.account_id}-${var.region}"

  github_owner_name = split("/", var.github_repo)[0]
  github_repo_name  = split("/", var.github_repo)[1]
  github_subject    = "repo:${local.github_owner_name}@${var.github_owner_id}/${local.github_repo_name}@${var.github_repository_id}:*"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

resource "aws_ecr_repository" "pz" {
  name                 = "${var.project}-server"
  image_tag_mutability = "IMMUTABLE" # Prevent :latest drift.

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "pz" {
  repository = aws_ecr_repository.pz.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_repository" "pz_backup" {
  name                 = "${var.project}-backup"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "pz_backup" {
  repository = aws_ecr_repository.pz_backup.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_repository" "pz_bootstrap" {
  name                 = "${var.project}-bootstrap"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "pz_bootstrap" {
  repository = aws_ecr_repository.pz_bootstrap.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_s3_bucket" "backups" {
  bucket = local.backup_bucket
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    filter {
      prefix = "${var.backup_prefix}/"
    }

    expiration {
      days = var.backup_retention_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

data "aws_iam_policy_document" "ecr_push" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
    ]
    resources = [
      aws_ecr_repository.pz.arn,
      aws_ecr_repository.pz_backup.arn,
      aws_ecr_repository.pz_bootstrap.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

output "state_bucket" {
  value       = aws_s3_bucket.tfstate.id
  description = "Use as the backend bucket in terraform/infra."
}

output "state_lock_table" {
  value = aws_dynamodb_table.tflock.name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.pz.repository_url
}

output "ecr_backup_repository_url" {
  value = aws_ecr_repository.pz_backup.repository_url
}

output "ecr_bootstrap_repository_url" {
  value       = aws_ecr_repository.pz_bootstrap.repository_url
  description = "Feeds the Bottlerocket bootstrap-container source in terraform/infra."
}

output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "Set as the AWS_ROLE_ARN repository variable in GitHub."
}

output "backup_bucket" {
  value       = aws_s3_bucket.backups.id
  description = "Set as PZ_BACKUP_BUCKET on the backup sidecar; grant the ECS task role s3:PutObject on it."
}
