variable "subscription_id" {
  description = "Azure subscription (the personal trial, never the work one)."
  type        = string
}

variable "admin_username" {
  description = "Login user. T-Pot's installer aborts if it is named `tpot`."
  type        = string
  default     = "alan"
}

variable "ssh_public_key" {
  description = "SSH public key for the login user."
  type        = string
}

variable "hive_wg_public_key" {
  description = "WireGuard public key of the hive VM at home; the hive dials out to each sensor."
  type        = string
}

variable "sensors" {
  description = "One entry per sensor. wg_address must be unique inside 10.101.0.0/24."
  type = map(object({
    location   = string
    size       = optional(string, "Standard_B2als_v2")
    disk_gb    = optional(number, 32)
    wg_address = string
  }))
}

# Kept apart from `sensors`: Terraform refuses to drive for_each from a sensitive value.
variable "sensor_secrets" {
  description = "Per-sensor secrets, keyed by the same names as `sensors`."
  type = map(object({
    wg_private_key = string
    web_password   = string
  }))
  sensitive = true
}
