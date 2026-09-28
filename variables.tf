variable "env_subscription_id" {
  type        = string
  description = "Azure Subscription ID where the pod will be deployed."
  sensitive   = true
}

variable "arm_location" {
  type        = string
  description = "Azure region for the pod."
  default     = "westus2"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for all resources."
  default     = "zscc"
  validation {
    condition     = length(var.name_prefix) <= 12
    error_message = "name_prefix must be 12 characters or fewer."
  }
}

variable "name_suffix" {
  type        = string
  description = "Unique per pod. Keep lowercase and short (used in public hostname)."
}

variable "network_address_space" {
  type        = string
  description = "VNet CIDR."
  default     = "10.1.0.0/16"
}

variable "cc_subnets" {
  type        = list(string)
  description = "Optional override for Cloud Connector subnet CIDRs."
  default     = null
}

variable "workloads_subnets" {
  type        = list(string)
  description = "Optional override for workload subnet CIDRs."
  default     = null
}

variable "public_subnets" {
  type        = list(string)
  description = "Optional override for bastion/App Gateway public subnet CIDRs."
  default     = null
}

variable "private_dns_subnet" {
  type        = string
  description = "Optional override for Azure Private DNS Resolver outbound endpoint subnet."
  default     = null
}

variable "environment" {
  type    = string
  default = "Development"
}

variable "owner_tag" {
  type    = string
  default = "zscc-admin"
}

# ---- DNS / TLS bootstrap outputs ----
variable "lab_domain" {
  type        = string
  description = "Apex lab domain from bootstrap outputs."
}

variable "dns_zone_resource_group_name" {
  type        = string
  description = "Resource group containing the Azure DNS zone (from bootstrap outputs)."
}

variable "wildcard_cert_secret_id" {
  type        = string
  description = "Key Vault secret ID of the wildcard PFX (from bootstrap outputs)."
}

# ---- Zscaler Cloud Connector ----
variable "cc_vm_prov_url" {
  type        = string
  description = "Zscaler Cloud Connector provisioning URL."
}

variable "secret_username" {
  type = string
}

variable "secret_password" {
  type = string
}

variable "secret_apikey" {
  type = string
}

variable "cc_vm_managed_identity_name" {
  type        = string
  description = "Pre-created User Assigned Managed Identity name for Cloud Connector."
}

variable "cc_vm_managed_identity_rg" {
  type        = string
  description = "Resource Group of the pre-created managed identity."
}

variable "ccvm_instance_type" {
  type        = string
  description = "Cloud Connector VM size."
  default     = "Standard_D2ds_v5"
  validation {
    condition = contains([
      "Standard_D2s_v3",
      "Standard_DS3_v2",
      "Standard_D2ds_v5",
      "Standard_D2ads_v5"
    ], var.ccvm_instance_type)
    error_message = "ccvm_instance_type must be an approved Cloud Connector VM size."
  }
}

variable "ccvm_image_publisher" {
  type    = string
  default = "zscaler1579058425289"
}

variable "ccvm_image_offer" {
  type    = string
  default = "zia_cloud_connector"
}

variable "ccvm_image_sku" {
  type    = string
  default = "zs_ser_gen1_cc_01"
}

variable "ccvm_image_version" {
  type    = string
  default = "latest"
}

variable "ccvm_source_image_id" {
  type        = string
  description = "Override Cloud Connector image with a custom image ID."
  default     = null
}

variable "http_probe_port" {
  type        = number
  default     = 50000
  description = "HTTP probe port for Cloud Connector and Azure LB."
}

variable "vmss_default_ccs" {
  type    = number
  default = 2
}

variable "vmss_min_ccs" {
  type    = number
  default = 2
}

variable "vmss_max_ccs" {
  type    = number
  default = 4
}

variable "fips_enabled" {
  type        = string
  default     = "False"
  description = "FIPS mode for Cloud Connector: 'False' or 'True'."
  validation {
    condition     = contains(["False", "True"], var.fips_enabled)
    error_message = "fips_enabled must be 'False' or 'True'."
  }
}

variable "zones_enabled" {
  type    = bool
  default = false
}

variable "zones" {
  type    = list(string)
  default = ["1"]
}

# ---- Bastion / Guacamole ----
variable "bastion_nsg_source_prefix" {
  type        = string
  default     = "*"
  description = "CIDR allowed to SSH to the bastion. '*' allows the Internet."
}

variable "bastion_admin_username" {
  type    = string
  default = "ubuntu"
}

variable "workload_admin_username" {
  type    = string
  default = "cloudconnector"
}

variable "workload_count" {
  type        = number
  default     = 2
  description = "Number of workload VMs to create."
}

# ---- ZPA ----
variable "zpa_client_id" {
  type = string
}

variable "zpa_client_secret" {
  type = string
}

variable "zpa_customer_id" {
  type = string
}

variable "ac_count" {
  type        = number
  default     = 1
  description = "Number of ZPA App Connector VMs to deploy."
}

variable "acvm_instance_type" {
  type    = string
  default = "Standard_B2s"
}

variable "acvm_image_publisher" {
  type    = string
  default = "Canonical"
}

variable "acvm_image_offer" {
  type    = string
  default = "0001-com-ubuntu-server-jammy"
}

variable "acvm_image_sku" {
  type    = string
  default = "22_04-lts-gen2"
}

variable "acvm_image_version" {
  type    = string
  default = "latest"
}

variable "acvm_source_image_id" {
  type    = string
  default = null
}

variable "domain_names" {
  type        = map(any)
  description = "Private DNS resolver domain forwarding rules for ZPA."
  default = {
    "zpa" = "*.zpa"
  }
}

variable "target_address" {
  type        = list(string)
  description = "Target IPs for private DNS forwarding."
  default     = ["185.46.212.88", "185.46.212.89"]
}

