terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.57"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    bucket         = "pz-tfstate-852891423863-us-east-2"
    key            = "infra/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "pz-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "project-zomboid"
      ManagedBy = "terraform"
      Stack     = "infra"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  registry   = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  backup_bucket = "${var.project}-backups-${local.account_id}-${var.region}"

  server_image    = "${local.registry}/${var.project}-server:${var.image_tag}"
  backup_image    = "${local.registry}/${var.project}-backup:${var.image_tag}"
  bootstrap_image = "${local.registry}/${var.project}-bootstrap:${var.image_tag}"
}
