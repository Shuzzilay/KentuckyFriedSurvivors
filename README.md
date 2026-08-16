# pz-server

Self-hosted Project Zomboid dedicated server: containerized, running on AWS.

## Layout

```
docker/               PZ server image, backup/restore sidecars, FIFO console, graceful shutdown
terraform/bootstrap/  Run once: state backend, ECR, GitHub OIDC role
terraform/infra/      Main stack: VPC, ECS, EC2 (Bottlerocket), EBS, Discord Lambda
lambda/discord/       Discord bot for server status and restarts
.github/workflows/    CI: shellcheck, config/shutdown harnesses, ECR image builds
```

## Features

- **Terraform-managed infrastructure.** `terraform/bootstrap/` provisions the Terraform state backend, ECR repositories, and the GitHub OIDC role once; `terraform/infra/` is the main stack (VPC, ECS, EC2, EBS, IAM, Discord integration) applied on every change. All server settings — ini keys, Sandbox variables, and admin roles — are declared in Terraform and patched into the world at boot.

- **ECR-backed images.** Three images (server, backup sidecar, Bottlerocket bootstrap) are built and pushed to ECR with immutable, commit-SHA tags, so a deployment always references an explicit, traceable image rather than a mutable `:latest`.

- **ECS on EC2 Bottlerocket.** The game runs as a single ECS task on a Bottlerocket host, with a custom bootstrap container that attaches and formats a persistent EBS data volume by tag. This keeps the world and installed server files intact across instance replacement while avoiding ECS-managed EBS, which Bottlerocket doesn't support.

- **GitHub Actions CI/CD.** Every push lints the shell scripts, runs a graceful-shutdown harness and a config-patcher harness against real Build 42 fixtures, and builds all three Docker images. Pushes to `main` authenticate to AWS via OIDC (no static keys) and push freshly tagged images to ECR.

- **Discord-Lambda control surface.** A Node.js Lambda behind Discord's interactions API powers `/pz server-status`, `/pz infra-status`, and an admin-gated `/pz restart`, letting players check on or restart the server without AWS access. Restart uses ECS `forceNewDeployment`, so the normal graceful-drain path always runs.

- **Automated backups and restore.** A backup sidecar saves the world and uploads an archive to S3 every 15 minutes; a dedicated read-only `pz-restore` ECS task verifies and restores an archive on demand, moving aside (not deleting) the live world first.
