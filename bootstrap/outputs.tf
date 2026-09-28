output "resource_group_name" {
  description = "Resource group containing the shared DNS zone and Key Vault."
  value       = azurerm_resource_group.bootstrap.name
}

output "lab_domain" {
  description = "Apex lab domain. Pass this as -var lab_domain=... to the pod stack."
  value       = var.lab_domain
}

output "dns_zone_id" {
  description = "ID of the Azure DNS zone."
  value       = azurerm_dns_zone.lab.id
}

output "dns_zone_name_servers" {
  description = "Delegate your registrar's NS records to these four values."
  value       = azurerm_dns_zone.lab.name_servers
}

output "key_vault_id" {
  description = "ID of the shared Key Vault holding the wildcard certificate."
  value       = azurerm_key_vault.bootstrap.id
}

output "key_vault_name" {
  description = "Name of the shared Key Vault."
  value       = azurerm_key_vault.bootstrap.name
}

output "wildcard_cert_secret_id" {
  description = "Key Vault secret ID of the wildcard PFX. Pass to the pod stack as -var wildcard_cert_secret_id=..."
  value       = data.azurerm_key_vault_secret.wildcard.id
}
