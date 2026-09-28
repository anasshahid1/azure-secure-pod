output "lab_url" {
  description = "Public HTTPS endpoint for the pod."
  value       = "https://${local.bastion_hostname}/"
}

output "bastion_public_ip" {
  description = "Bastion public IP (for SSH troubleshooting)."
  value       = azurerm_public_ip.bastion_pip.ip_address
}

output "bastion_private_ip" {
  description = "Bastion private IP."
  value       = azurerm_network_interface.bastion_nic.private_ip_address
}

output "bastion_username" {
  description = "Bastion OS username."
  value       = var.bastion_admin_username
}

output "workload_private_ips" {
  description = "Workload VM private IPs."
  value       = azurerm_linux_virtual_machine.workload[*].private_ip_address
}

output "workload_admin_username" {
  value = var.workload_admin_username
}

output "cc_lb_ip" {
  description = "Cloud Connector internal load balancer frontend IP."
  value       = module.cc_lb.lb_ip
}

output "resource_group_name" {
  description = "Resource group for this pod."
  value       = module.network.resource_group_name
}

output "ac_public_ip" {
  description = "ZPA App Connector public IP."
  value       = length(azurerm_public_ip.ac_pip) > 0 ? azurerm_public_ip.ac_pip[0].ip_address : ""
}

output "portal_username" {
  value = var.secret_username
}

output "portal_password" {
  value     = var.secret_password
  sensitive = true
}

output "wkld_username" {
  value = var.workload_admin_username
}

output "usermapping" {
  value     = local.usermapping
  sensitive = true
}
