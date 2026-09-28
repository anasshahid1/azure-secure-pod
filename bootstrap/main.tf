provider "azurerm" {
  features {}
}

data "azurerm_client_config" "current" {}

locals {
  global_tags = {
    Owner       = var.owner_tag
    ManagedBy   = "terraform"
    Vendor      = "Zscaler"
    Environment = var.environment
  }
}

resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_resource_group" "bootstrap" {
  name     = "${var.name_prefix}-bootstrap-${random_string.suffix.result}"
  location = var.arm_location
  tags     = local.global_tags
}

resource "azurerm_dns_zone" "lab" {
  name                = var.lab_domain
  resource_group_name = azurerm_resource_group.bootstrap.name

  tags = local.global_tags
}

resource "azurerm_key_vault" "bootstrap" {
  name                       = "${var.name_prefix}kv${random_string.suffix.result}"
  location                   = var.arm_location
  resource_group_name        = azurerm_resource_group.bootstrap.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = local.global_tags
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.bootstrap.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions      = ["Get", "List", "Set", "Delete", "Purge"]
  certificate_permissions = ["Get", "List", "Create", "Delete", "Update", "Purge"]
  key_permissions         = ["Get", "List", "Create", "Delete", "Update", "Purge"]
}

resource "azurerm_key_vault_certificate" "wildcard" {
  name         = "wildcard-${replace(var.lab_domain, ".", "-")}"
  key_vault_id = azurerm_key_vault.bootstrap.id

  depends_on = [azurerm_key_vault_access_policy.terraform]

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      subject            = "CN=*.${var.lab_domain}"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]

      subject_alternative_names {
        dns_names = ["*.${var.lab_domain}", var.lab_domain]
      }
    }
  }
}

# The PFX that Application Gateway needs lives as a Key Vault secret with the same name as the certificate.
data "azurerm_key_vault_secret" "wildcard" {
  name         = azurerm_key_vault_certificate.wildcard.name
  key_vault_id = azurerm_key_vault.bootstrap.id

  depends_on = [azurerm_key_vault_certificate.wildcard]
}
