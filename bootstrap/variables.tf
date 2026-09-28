variable "name_prefix" {
  type        = string
  description = "Short prefix for all bootstrap resources. Keep <= 10 chars because Key Vault names are limited to 24 characters."
  default     = "zscc"
}

variable "lab_domain" {
  type        = string
  description = "Apex lab domain you own (e.g. ztcloudlab.com). You must delegate its NS records to Azure DNS after bootstrap."
  default     = "ztcloudlab.com"
}

variable "arm_location" {
  type        = string
  description = "Azure region for the bootstrap resources. Must match the region where Application Gateway will be created."
  default     = "westus2"
}

variable "environment" {
  type    = string
  default = "Development"
}

variable "owner_tag" {
  type    = string
  default = "zscc-admin"
}
