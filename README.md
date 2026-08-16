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

- **Terraform-managed infrastructure.** `terraform/bootstrap/` provisions the Terraform state backend, ECR repositories, and the GitHub OIDC role once; `terraform/infra/` is the main stack (VPC, ECS, EC2, EBS, IAM, Discord integration) applied on every change. Server settings, Sandbox variables, mods, and Steam-ID-based admin roles are declared in Terraform and applied at boot.

- **ECR-backed images.** Three images (server, backup sidecar, Bottlerocket bootstrap) are built and pushed to ECR with immutable, commit-SHA tags, so a deployment always references an explicit, traceable image rather than a mutable `:latest`.

- **ECS on EC2 Bottlerocket.** The game runs as a single ECS task on a Bottlerocket host. A custom bootstrap container attaches the persistent EBS data volume and claims the server's Elastic IP by tag, preserving both the world and player connection address across instance replacement.

- **GitHub Actions CI/CD.** Docker changes lint the shell scripts, run graceful-shutdown and config-patcher harnesses against Build 42 fixtures, and build all three images. Matching pushes to `main` authenticate to AWS through OIDC and publish immutable commit-SHA tags to ECR.

- **Discord-Lambda control surface.** A Node.js Lambda behind Discord's interactions API powers `/pz server-status`, `/pz infra-status`, and an admin-gated `/pz restart`, letting players check on or restart the server without AWS access. Restart uses ECS `forceNewDeployment`, so the normal graceful-drain path always runs.

- **Automated backups and restore.** A backup sidecar saves the world and uploads an archive to S3 every 15 minutes; a dedicated read-only `pz-restore` ECS task verifies and restores an archive on demand, moving aside (not deleting) the live world first.
