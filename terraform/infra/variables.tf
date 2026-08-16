
variable "region" {
  description = "AWS region. Must match the bootstrap stack."
  type        = string
  default     = "us-east-2"
}

variable "project" {
  description = "Name prefix for all resources. Must match the bootstrap stack."
  type        = string
  default     = "pz"
}

variable "image_tag" {
  description = <<-EOT
    Commit SHA to deploy. ECR repos are IMMUTABLE, so there is no :latest to
    fall back on - this is deliberately an explicit, auditable choice of build.
    Find candidates with:
      aws ecr list-images --repository-name pz-server
  EOT
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    PZ is largely single-threaded and x86_64-only (no Graviton). Prefer fast
    cores over many. m6i.xlarge (4 vCPU / 16 GiB) leaves comfortable headroom
    for an 8g heap; at ~$0.19/hr on-demand it is the bulk of the ~$160/mo this
    project accepted as the cost of learning.
  EOT
  type        = string
  default     = "m6i.xlarge"
}

variable "data_volume_size" {
  description = <<-EOT
    GiB for the persistent world volume. Sized for the ~7GB base game install
    (kept here so a task replacement does not re-download it), Workshop mods,
    and the save itself.
  EOT
  type        = number
  default     = 50
}

variable "container_stop_timeout" {
  description = <<-EOT
    How long ECS waits for the container to drain before SIGKILL, as a
    Bottlerocket duration.

    This is the setting the whole Bottlerocket decision hinged on. Measured
    drain on an empty world was ~40s (2s warn + 25s fixed save wait + 13s JVM
    exit), which already exceeds the ECS agent's 30s default - leaving it at
    the default would SIGKILL the server mid-save. 2m leaves room for a
    populated world, where the save flush will take longer.
  EOT
  type        = string
  default     = "2m"
}

variable "task_stop_timeout_seconds" {
  description = <<-EOT
    Container-level stopTimeout in the task definition. Must be <= the host's
    container_stop_timeout above, and ECS caps this at 120s.
  EOT
  type        = number
  default     = 120
}

variable "pz_memory" {
  description = <<-EOT
    JVM heap, passed to entrypoint.sh which patches it into PZ's launcher. PZ
    ships a 16g default that would OOM this instance. Container memory limits
    do NOT constrain the JVM - only this does.
  EOT
  type        = string
  default     = "8g"
}

variable "server_name" {
  description = "PZ server name. Determines the save directory name - changing it later orphans the existing world."
  type        = string
  default     = "servertest"
}

variable "admin_password_parameter" {
  description = <<-EOT
    Name of the SSM SecureString holding the server admin password. Created out
    of band on purpose (see main.tf header) so the secret never enters state.
  EOT
  type        = string
  default     = "/pz/admin-password"
}

variable "ini_settings" {
  description = <<-EOT
    Keys written into Zomboid/Server/<server_name>.ini at container boot.

    This exists because the ini is otherwise unmanaged: it is generated on first
    boot, lives only on the EBS volume, and PZ rewrites it on shutdown - so an
    edit made against a running server is discarded. Patching at boot makes this
    file derived state and Terraform the source of truth.

    Keys are matched case-insensitively against the file's own names; an unknown
    key fails the boot rather than being silently ignored. Passwords do NOT
    belong here (they would land in plaintext state) - see the *_parameter
    variables below.
  EOT
  type        = map(string)
  default = {
    PublicName                = "Derp Enterprise"
    PublicDescription         = "Here be derp"
    ServerWelcomeMessage      = "If you're reading this, you're gay."
    Public                    = "true"
    DisplayUserName           = "false"
    MouseOverToSeeDisplayName = "false"
    ShowFirstAndLastName      = "true"
    SpeedLimit                = "100.0"
    SteamScoreboard           = "true"

  }
}

variable "sandbox_config_file" {
  description = <<-EOT
    Path to the YAML file holding sandbox (gameplay) settings, relative to this
    module. Kept out of Terraform as a plain, commented data file: it is the
    knob operators actually turn, the key space is ~275 entries deep, and it
    reads far better with the enum meanings written next to the values.
  EOT
  type        = string
  default     = "sandbox.yaml"
}

variable "mods_config_file" {
  description = <<-EOT
    Path to the YAML file listing Workshop mods, relative to this module.

    Kept out of Terraform for the same reason as the sandbox settings, plus one
    specific to mods: PZ needs two different values per mod (the numeric
    Workshop ID that downloads, and the text Mod IDs from mod.info that load),
    they are not 1:1, and they must stay written down together. The file groups
    them per mod; config.tf flattens them into the ini keys.
  EOT
  type        = string
  default     = "mods.yaml"
}

variable "base_map" {
  description = <<-EOT
    The base map, kept last in the Map= list when map mods are present. PZ has
    a singular Map= key and no Maps= option, and map folders are prepended
    ahead of the base map. Unused until a map mod is added.
  EOT
  type        = string
  default     = "Muldraugh, KY"
}

variable "admin_users" {
  description = <<-EOT
    Accounts promoted to the admin role at container boot.

    B42 stores access level in the user DB (whitelist.role, an FK into the role
    table where 7 = admin), not in the ini - the old accesslevel column is gone.
    An account must have connected at least once before it can be promoted;
    promotion of an unknown name logs a warning and is otherwise a no-op.
  EOT
  type        = list(string)
  default     = ["test"]
}

variable "server_password_parameter" {
  description = <<-EOT
    Optional SSM SecureString name holding the server join password, injected as
    an ini setting at boot. Empty leaves the server open (subject to the
    security group). Kept out of Terraform for the same reason as the admin
    password: state is readable plaintext JSON.

    The name is not a secret and belongs here where it is reviewable; only the
    value lives in SSM. Must exist before apply - a task definition pointing at
    a missing parameter fails to start rather than starting without it.
  EOT
  type        = string
  default     = "/pz/server-password"
}

variable "rcon_password_parameter" {
  description = <<-EOT
    Optional SSM SecureString name holding the RCON password. Empty disables
    RCON auth config. Same rules as server_password_parameter above.
  EOT
  type        = string
  default     = "/pz/rcon-password"
}

variable "discord_public_key" {
  description = <<-EOT
    Discord application's public key, used to verify the Ed25519 signature on
    every interaction. Empty disables the whole Discord stack, so this can live
    in the repo before the application exists.

    Not a secret - it is the public half, published on the application's own
    page, and it verifies rather than authorises. It is config, so it belongs
    here where it is reviewable.
  EOT
  type        = string
  default     = "2287746b30354ad245178ad57045d60d3acce61e1a04fd48b2e898d09795730d"
}

variable "discord_guild_id" {
  description = <<-EOT
    The one Discord server allowed to use these commands. A valid signature
    only proves Discord sent the request, not that it came from the right
    guild - without this check, anyone who added the app to their own server
    could restart this one.
  EOT
  type        = string
  default     = "356569257141731339"
}

variable "discord_channel_id" {
  description = <<-EOT
    The only channel these commands work in (#zomboid-bot). Empty allows any
    channel in the guild.

    Discord can hide a command from other channels through its own permissions
    UI, but that is presentation rather than enforcement - the command can
    still be invoked, and any guild admin can change those settings without
    touching this repo. Checking it in the Lambda makes it a rule.
  EOT
  type        = string
  default     = "1216194017910591528"
}

variable "discord_admin_role_id" {
  description = <<-EOT
    Role ID permitted to run /pz restart. Status is open to everyone in the
    guild; restarting is not. Discord sends the invoking member's role IDs in
    the interaction payload, so this is checked without any extra API call.
  EOT
  type        = string
  default     = "356586174103683073"
}

variable "allowed_player_cidrs" {
  description = <<-EOT
    Who may reach the game ports. Defaults to the whole internet because that
    is what a public game server is; narrow it if the player list is fixed.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "backup_interval" {
  description = "Seconds between backup cycles. 15 minutes is the accepted crash-fallback cadence, not an archive."
  type        = number
  default     = 900
}

variable "backup_prefix" {
  description = "S3 key prefix for backups. Must match the bootstrap stack's lifecycle rule, or backups will never expire."
  type        = string
  default     = "backups"
}

variable "metric_namespace" {
  description = <<-EOT
    CloudWatch namespace for metrics the containers publish about themselves.

    Currently just world-volume usage, from the backup sidecar. Nothing in AWS
    can observe that from outside: EBS reports the volume's provisioned size,
    not the filesystem's usage, so the only thing able to measure it is a
    process with the volume mounted.
  EOT
  type        = string
  default     = "PZServer"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Long enough to debug a bad weekend, short enough to stay cheap."
  type        = number
  default     = 14
}
