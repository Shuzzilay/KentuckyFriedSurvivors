locals {
  sandbox_raw = yamldecode(file("${path.module}/${var.sandbox_config_file}"))

  sandbox_settings = { for k, v in local.sandbox_raw : k => tostring(v) }

  mods_raw = yamldecode(file("${path.module}/${var.mods_config_file}"))
  mods     = try(local.mods_raw.mods, [])

  mod_map_folders = flatten([for m in local.mods : try(m.map_folders, [])])

  mod_ini_settings = merge(
    {
      WorkshopItems = join(";", [for m in local.mods : tostring(m.workshop_id)])
      Mods          = join(";", flatten([for m in local.mods : m.mod_ids]))
    },
    length(local.mod_map_folders) > 0 ? {
      Map = join(";", concat(local.mod_map_folders, [var.base_map]))
    } : {},
  )

  pz_config_environment = concat(
    [for k, v in merge(var.ini_settings, local.mod_ini_settings) : {
      name  = "PZ_INI_${k}"
      value = v
    }],
    [for k, v in local.sandbox_settings : {
      name  = "PZ_SANDBOX_${replace(k, ".", "__")}"
      value = v
    }],
    length(var.admin_steam_ids) > 0 ? [{
      name  = "PZ_ADMIN_STEAM_IDS"
      value = join(",", var.admin_steam_ids)
    }] : [],
  )

  pz_config_secrets = concat(
    var.server_password_parameter != "" ? [{
      name      = "PZ_INI_Password"
      valueFrom = "arn:aws:ssm:${var.region}:${local.account_id}:parameter${var.server_password_parameter}"
    }] : [],
    var.rcon_password_parameter != "" ? [{
      name      = "PZ_INI_RCONPassword"
      valueFrom = "arn:aws:ssm:${var.region}:${local.account_id}:parameter${var.rcon_password_parameter}"
    }] : [],
  )
}
