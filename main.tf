provider "azurerm" {
  subscription_id = var.env_subscription_id
  features {}
}

provider "zpa" {
  use_legacy_client = true
  zpa_client_id     = var.zpa_client_id
  zpa_client_secret = var.zpa_client_secret
  zpa_customer_id   = var.zpa_customer_id
  zpa_cloud         = var.zpa_cloud
}

data "azurerm_client_config" "current" {}

locals {
  resource_tag = lower(var.name_suffix)
  global_tags = {
    Owner       = var.owner_tag
    ManagedBy   = "terraform"
    Vendor      = "Zscaler"
    Environment = var.environment
  }

  vnet_name        = "${var.name_prefix}-vnet-${local.resource_tag}"
  bastion_hostname = "pod-${local.resource_tag}.${var.lab_domain}"

  cc_vault_url = var.cc_azure_vault_url != "" ? var.cc_azure_vault_url : azurerm_key_vault.cc[0].vault_uri

  cc_userdata = <<USERDATA
[ZSCALER]
CC_URL=${startswith(var.cc_vm_prov_url, "http") ? var.cc_vm_prov_url : "https://${var.cc_vm_prov_url}"}
AZURE_VAULT_URL=${local.cc_vault_url}
HTTP_PROBE_PORT=${var.http_probe_port}
AZURE_MANAGED_IDENTITY_CLIENT_ID=${module.cc_identity.managed_identity_client_id}
FIPS_ENABLED=${var.fips_enabled}
USERDATA

  guacamole_cloud_init = <<CI
#cloud-config
package_update: true
packages:
  - docker.io
  - curl
  - tar
write_files:
  - path: /etc/guacamole/user-mapping.xml
    permissions: '0644'
    owner: root:root
    encoding: b64
    content: ${base64encode(local.usermapping)}
runcmd:
  - systemctl enable docker
  - systemctl start docker
  - docker network create guacnetwork || true
  - mkdir -p /etc/guacamole/extensions
  - |
    curl -fsSL https://archive.apache.org/dist/guacamole/1.5.5/binary/guacamole-auth-file-1.5.5.tar.gz \
      -o /tmp/guacamole-auth-file.tar.gz && \
    tar -xzf /tmp/guacamole-auth-file.tar.gz -C /tmp && \
    find /tmp -name 'guacamole-auth-file-*.jar' -exec mv {} /etc/guacamole/extensions/ \; && \
    rm -rf /tmp/guacamole-auth-file.tar.gz /tmp/guacamole-auth-file-1.5.5
  - docker run -d --restart always --name guacd --network guacnetwork guacamole/guacd:latest
  - |
    docker run -d --restart always --name guacamole \
      --network guacnetwork \
      -p 8080:8080 \
      -v /etc/guacamole:/etc/guacamole \
      -e GUACAMOLE_HOME=/etc/guacamole \
      -e GUACD_HOSTNAME=guacd \
      -e GUACD_PORT=4822 \
      guacamole/guacamole:latest
CI
}

################################################################################
# SSH key pair (stored locally as a .pem file)
################################################################################
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "local_file" "private_key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "${var.name_prefix}-key-${local.resource_tag}.pem"
  file_permission = "0600"
}

################################################################################
# 1. VNet / subnets / NATGW / route tables (official Zscaler module)
################################################################################
module "network" {
  source                = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-network-azure?ref=main"
  name_prefix           = var.name_prefix
  resource_tag          = local.resource_tag
  global_tags           = local.global_tags
  location              = var.arm_location
  network_address_space = var.network_address_space
  cc_subnets            = var.cc_subnets
  workloads_subnets     = var.workloads_subnets
  public_subnets        = var.public_subnets
  private_dns_subnet    = var.private_dns_subnet
  zones_enabled         = var.zones_enabled
  zones                 = var.zones
  lb_frontend_ip        = module.cc_lb.lb_ip
  workloads_enabled     = true
  bastion_enabled       = true
  zpa_enabled           = true
}

################################################################################
# 2. Application Gateway subnet, public IP, and Application Gateway
################################################################################
resource "azurerm_subnet" "appgw" {
  count                = var.deploy_public_endpoint ? 1 : 0
  name                 = "${var.name_prefix}-appgw-subnet-${local.resource_tag}"
  resource_group_name  = module.network.resource_group_name
  virtual_network_name = local.vnet_name
  address_prefixes     = var.public_subnets != null && length(var.public_subnets) > 1 ? [var.public_subnets[1]] : [cidrsubnet(var.network_address_space, 8, 102)]

  depends_on = [module.network]
}

resource "azurerm_public_ip" "appgw_pip" {
  count               = var.deploy_public_endpoint ? 1 : 0
  name                = "${var.name_prefix}-appgw-pip-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "pod-${local.resource_tag}"

  tags = local.global_tags
}

resource "azurerm_application_gateway" "bastion" {
  count               = var.deploy_public_endpoint ? 1 : 0
  name                = "${var.name_prefix}-appgw-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location

  sku {
    name = "Standard_v2"
    tier = "Standard_v2"
  }

  autoscale_configuration {
    min_capacity = 1
    max_capacity = 2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw[0].id
  }

  frontend_port {
    name = "https"
    port = 443
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-public-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip[0].id
  }

  ssl_certificate {
    name                = "wildcard"
    key_vault_secret_id = var.wildcard_cert_secret_id
  }

  backend_address_pool {
    name         = "bastion-pool"
    ip_addresses = [azurerm_network_interface.bastion_nic.private_ip_address]
  }

  backend_http_settings {
    name                  = "bastion-8080"
    port                  = 8080
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 60
    probe_name            = "guacamole"
  }

  probe {
    name                = "guacamole"
    host                = "127.0.0.1"
    protocol            = "Http"
    path                = "/guacamole/"
    interval            = 30
    timeout             = 10
    unhealthy_threshold = 5

    match {
      status_code = ["200-399"]
    }
  }

  http_listener {
    name                           = "https"
    frontend_ip_configuration_name = "appgw-public-ip"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "wildcard"
    host_name                      = local.bastion_hostname
  }

  http_listener {
    name                           = "http"
    frontend_ip_configuration_name = "appgw-public-ip"
    frontend_port_name             = "http"
    protocol                       = "Http"
    host_name                      = local.bastion_hostname
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https"
    rule_type                  = "Basic"
    http_listener_name         = "https"
    backend_address_pool_name  = "bastion-pool"
    backend_http_settings_name = "bastion-8080"
    priority                   = 100
  }

  request_routing_rule {
    name                        = "http"
    rule_type                   = "Basic"
    http_listener_name          = "http"
    redirect_configuration_name = "http-to-https"
    priority                    = 110
  }

  tags = local.global_tags

  depends_on = [azurerm_network_interface.bastion_nic]
}

################################################################################
# 3. Guacamole Bastion VM
################################################################################
resource "azurerm_network_security_group" "bastion_nsg" {
  name                = "${var.name_prefix}-bastion-nsg-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  security_rule {
    name                       = "SSH"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.bastion_nsg_source_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Guacamole"
    priority                   = 4001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.deploy_public_endpoint ? azurerm_subnet.appgw[0].address_prefixes[0] : var.bastion_nsg_source_prefix
    destination_address_prefix = "*"
  }

  tags = local.global_tags
}

resource "azurerm_public_ip" "bastion_pip" {
  name                = "${var.name_prefix}-bastion-pip-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.global_tags
}

resource "azurerm_network_interface" "bastion_nic" {
  name                = "${var.name_prefix}-bastion-nic-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  ip_configuration {
    name                          = "bastion-ip-config"
    subnet_id                     = module.network.bastion_subnet_ids[0]
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.bastion_pip.id
  }

  tags = local.global_tags
}

resource "azurerm_network_interface_security_group_association" "bastion_nic_nsg" {
  network_interface_id      = azurerm_network_interface.bastion_nic.id
  network_security_group_id = azurerm_network_security_group.bastion_nsg.id
}

resource "azurerm_linux_virtual_machine" "bastion" {
  name                  = "${var.name_prefix}-bastion-vm-${local.resource_tag}"
  location              = var.arm_location
  resource_group_name   = module.network.resource_group_name
  network_interface_ids = [azurerm_network_interface.bastion_nic.id]
  size                  = var.bastion_instance_type
  admin_username        = var.bastion_admin_username
  computer_name         = "${var.name_prefix}-bastion-${local.resource_tag}"

  admin_ssh_key {
    username   = var.bastion_admin_username
    public_key = "${trimspace(tls_private_key.key.public_key_openssh)} ${var.bastion_admin_username}@me.io"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(local.guacamole_cloud_init)

  tags = local.global_tags

  depends_on = [
    azurerm_network_interface.bastion_nic,
    azurerm_network_interface_security_group_association.bastion_nic_nsg
  ]
}

################################################################################
# 4. Workload VMs (Ubuntu + XRDP for RDP + SSH)
################################################################################
resource "azurerm_network_security_group" "workload_nsg" {
  name                = "${var.name_prefix}-workload-nsg-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  security_rule {
    name                       = "SSH_VNET"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "RDP_VNET"
    priority                   = 4001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "ICMP_VNET"
    priority                   = 4002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "OUTBOUND"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.global_tags
}

resource "azurerm_network_interface" "workload_nic" {
  count               = var.workload_count
  name                = "${var.name_prefix}-workload-nic-${count.index + 1}-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  ip_configuration {
    name                          = "workload-ip-config"
    subnet_id                     = module.network.workload_subnet_ids[0]
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.global_tags
}

resource "azurerm_network_interface_security_group_association" "workload_nic_nsg" {
  count                     = var.workload_count
  network_interface_id      = azurerm_network_interface.workload_nic[count.index].id
  network_security_group_id = azurerm_network_security_group.workload_nsg.id
}

resource "azurerm_linux_virtual_machine" "workload" {
  count               = var.workload_count
  name                = "${var.name_prefix}-workload-vm-${count.index + 1}-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  network_interface_ids = [azurerm_network_interface.workload_nic[count.index].id]
  size                  = var.workload_instance_type
  admin_username        = var.workload_admin_username
  computer_name         = "${var.name_prefix}-workload-${count.index + 1}-${local.resource_tag}"

  admin_ssh_key {
    username   = var.workload_admin_username
    public_key = "${trimspace(tls_private_key.key.public_key_openssh)} ${var.workload_admin_username}@me.io"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<-WCI
#cloud-config
package_update: true
packages:
  - xrdp
  - xfce4
  - xfce4-goodies
runcmd:
  - echo '${var.workload_admin_username}:CloudConnector2022!' | chpasswd
  - systemctl enable xrdp
  - systemctl start xrdp
WCI
  )

  tags = local.global_tags

  depends_on = [
    azurerm_network_interface.workload_nic,
    azurerm_network_interface_security_group_association.workload_nic_nsg
  ]
}

################################################################################
# 5. Cloud Connector LB, NSG, Identity, and VMSS
################################################################################
module "cc_lb" {
  source            = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-lb-azure?ref=main"
  name_prefix       = var.name_prefix
  resource_tag      = local.resource_tag
  global_tags       = local.global_tags
  resource_group    = module.network.resource_group_name
  location          = var.arm_location
  subnet_id         = module.network.cc_subnet_ids[0]
  http_probe_port   = var.http_probe_port
  load_distribution = "Default"
  zones_enabled     = var.zones_enabled
  zones             = var.zones
}

module "cc_nsg" {
  source                 = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-nsg-azure?ref=main"
  nsg_count              = 1
  name_prefix            = var.name_prefix
  resource_tag           = local.resource_tag
  resource_group         = module.network.resource_group_name
  location               = var.arm_location
  global_tags            = local.global_tags
  support_access_enabled = true
  public_lb_deployed     = false
}

module "cc_identity" {
  source                             = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-identity-azure?ref=main"
  cc_vm_managed_identity_name        = var.cc_vm_managed_identity_name
  cc_vm_managed_identity_rg          = var.cc_vm_managed_identity_rg
  vmss_enabled                       = true
  function_app_managed_identity_name = var.cc_vm_managed_identity_name
  function_app_managed_identity_rg   = var.cc_vm_managed_identity_rg
}

# Per-pod Key Vault for Cloud Connector credentials
resource "azurerm_key_vault" "cc" {
  count                      = var.cc_azure_vault_url == "" ? 1 : 0
  name                       = "${var.name_prefix}cc${local.resource_tag}"
  location                   = var.arm_location
  resource_group_name        = module.network.resource_group_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = local.global_tags
}

resource "azurerm_key_vault_access_policy" "cc_managed_identity" {
  count        = var.cc_azure_vault_url == "" ? 1 : 0
  key_vault_id = azurerm_key_vault.cc[0].id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = module.cc_identity.managed_identity_principal_id

  secret_permissions = ["Get", "List"]
}

resource "azurerm_key_vault_secret" "cc_username" {
  count        = var.cc_azure_vault_url == "" ? 1 : 0
  name         = "username"
  value        = var.secret_username
  key_vault_id = azurerm_key_vault.cc[0].id
}

resource "azurerm_key_vault_secret" "cc_password" {
  count        = var.cc_azure_vault_url == "" ? 1 : 0
  name         = "password"
  value        = var.secret_password
  key_vault_id = azurerm_key_vault.cc[0].id
}

resource "azurerm_key_vault_secret" "cc_apikey" {
  count        = var.cc_azure_vault_url == "" ? 1 : 0
  name         = "api-key"
  value        = var.secret_apikey
  key_vault_id = azurerm_key_vault.cc[0].id
}

resource "local_file" "cc_user_data" {
  content  = local.cc_userdata
  filename = "cc_user_data.txt"
}

module "cc_vmss" {
  source                         = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-ccvmss-azure?ref=main"
  location                       = var.arm_location
  name_prefix                    = var.name_prefix
  resource_tag                   = local.resource_tag
  global_tags                    = local.global_tags
  resource_group                 = module.network.resource_group_name
  mgmt_subnet_id                 = module.network.cc_subnet_ids
  service_subnet_id              = module.network.cc_subnet_ids
  ssh_key                        = tls_private_key.key.public_key_openssh
  managed_identity_id            = module.cc_identity.managed_identity_id
  user_data                      = local.cc_userdata
  backend_address_pool           = module.cc_lb.lb_backend_address_pool
  zones_enabled                  = var.zones_enabled
  zones                          = var.zones
  ccvm_instance_type             = var.ccvm_instance_type
  ccvm_image_publisher           = var.ccvm_image_publisher
  ccvm_image_offer               = var.ccvm_image_offer
  ccvm_image_sku                 = var.ccvm_image_sku
  ccvm_image_version             = var.ccvm_image_version
  ccvm_source_image_id           = var.ccvm_source_image_id
  mgmt_nsg_id                    = module.cc_nsg.mgmt_nsg_id[0]
  service_nsg_id                 = module.cc_nsg.service_nsg_id[0]
  accelerated_networking_enabled = true
  encryption_at_host_enabled     = true
  public_lb_deployed             = false
  vmss_default_ccs               = var.vmss_default_ccs
  vmss_min_ccs                   = var.vmss_min_ccs
  vmss_max_ccs                   = var.vmss_max_ccs
  scale_out_threshold            = 70
  scale_in_threshold             = 50

  depends_on = [
    azurerm_key_vault_secret.cc_username,
    azurerm_key_vault_secret.cc_password,
    azurerm_key_vault_secret.cc_apikey,
    azurerm_key_vault_access_policy.cc_managed_identity
  ]
}

module "cc_function_app" {
  source                     = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-function-app-azure?ref=main"
  name_prefix                = var.name_prefix
  resource_tag               = local.resource_tag
  global_tags                = local.global_tags
  resource_group             = module.network.resource_group_name
  location                   = var.arm_location
  cc_vm_prov_url             = var.cc_vm_prov_url
  azure_vault_url            = local.cc_vault_url
  vmss_names                 = module.cc_vmss.vmss_names
  managed_identity_id        = module.cc_identity.function_app_managed_identity_id
  managed_identity_client_id = module.cc_identity.function_app_managed_identity_client_id
  upload_function_app_zip    = true
  run_manual_sync            = false
  path_to_scripts            = ""
}

################################################################################
# 6. ZPA Private DNS Resolver
################################################################################
module "private_dns" {
  source                = "github.com/zscaler/terraform-azurerm-cloud-connector-modules//modules/terraform-zscc-private-dns-azure?ref=main"
  name_prefix           = var.name_prefix
  resource_tag          = local.resource_tag
  global_tags           = local.global_tags
  resource_group        = module.network.resource_group_name
  location              = var.arm_location
  vnet_id               = module.network.virtual_network_id
  private_dns_subnet_id = module.network.private_dns_subnet_id
  domain_names          = var.domain_names
  target_address        = var.target_address
}

resource "azurerm_private_dns_resolver_virtual_network_link" "dns_vnet_link" {
  name                      = "${var.name_prefix}-vnet-link-${local.resource_tag}"
  dns_forwarding_ruleset_id = module.private_dns.private_dns_forwarding_ruleset_id
  virtual_network_id        = module.network.virtual_network_id
}

################################################################################
# 7. ZPA App Connector Group + Provisioning Key + AC VM (separate VNet)
################################################################################
resource "zpa_app_connector_group" "app_connector_group" {
  name                     = "${var.name_prefix}-ac-group-${local.resource_tag}"
  description              = "Azure App Connector Group"
  enabled                  = true
  latitude                 = "37.33874"
  longitude                = "-121.8852525"
  location                 = "San Jose, CA, USA"
  upgrade_day              = "SUNDAY"
  upgrade_time_in_secs     = "66600"
  override_version_profile = true
  version_profile_id       = 0
  dns_query_type           = "IPV4_IPV6"
  enrollment_cert_id       = data.zpa_enrollment_cert.connector.id
}

resource "zpa_provisioning_key" "app_connector_provisioning_key" {
  name               = "${var.name_prefix}-ac-key-${local.resource_tag}"
  association_type   = "CONNECTOR_GRP"
  max_usage          = "10"
  enrollment_cert_id = data.zpa_enrollment_cert.connector.id
  zcomponent_id      = zpa_app_connector_group.app_connector_group.id
}

data "zpa_enrollment_cert" "connector" {
  name = "Connector"
}

resource "azurerm_marketplace_agreement" "ac_image" {
  count     = var.accept_marketplace_agreement ? 1 : 0
  publisher = var.acvm_image_publisher
  offer     = var.acvm_image_offer
  plan      = var.acvm_image_sku
}

# Separate VNet for App Connector
resource "azurerm_virtual_network" "ac_vnet" {
  name                = "${var.name_prefix}-ac-vnet-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location
  address_space       = ["10.2.0.0/16"]

  tags = local.global_tags
}

resource "azurerm_subnet" "ac" {
  name                 = "${var.name_prefix}-ac-subnet-${local.resource_tag}"
  resource_group_name  = module.network.resource_group_name
  virtual_network_name = azurerm_virtual_network.ac_vnet.name
  address_prefixes     = [cidrsubnet("10.2.0.0/16", 8, 1)]
}

# Peer the AC VNet to the CC/Workload VNet
resource "azurerm_virtual_network_peering" "cc_to_ac" {
  name                      = "${var.name_prefix}-cc-to-ac-${local.resource_tag}"
  resource_group_name       = module.network.resource_group_name
  virtual_network_name      = local.vnet_name
  remote_virtual_network_id = azurerm_virtual_network.ac_vnet.id

  depends_on = [module.network, azurerm_virtual_network.ac_vnet]
}

resource "azurerm_virtual_network_peering" "ac_to_cc" {
  name                      = "${var.name_prefix}-ac-to-cc-${local.resource_tag}"
  resource_group_name       = module.network.resource_group_name
  virtual_network_name      = azurerm_virtual_network.ac_vnet.name
  remote_virtual_network_id = module.network.virtual_network_id

  depends_on = [module.network, azurerm_virtual_network.ac_vnet]
}

# NAT Gateway for AC outbound internet access
resource "azurerm_public_ip" "ac_nat_pip" {
  name                = "${var.name_prefix}-ac-nat-pip-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = local.global_tags
}

resource "azurerm_nat_gateway" "ac_nat" {
  name                = "${var.name_prefix}-ac-nat-${local.resource_tag}"
  resource_group_name = module.network.resource_group_name
  location            = var.arm_location
  sku_name            = "Standard"

  tags = local.global_tags
}

resource "azurerm_nat_gateway_public_ip_association" "ac_nat_pip" {
  nat_gateway_id       = azurerm_nat_gateway.ac_nat.id
  public_ip_address_id = azurerm_public_ip.ac_nat_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "ac_nat_subnet" {
  subnet_id      = azurerm_subnet.ac.id
  nat_gateway_id = azurerm_nat_gateway.ac_nat.id
}

resource "azurerm_network_security_group" "ac_nsg" {
  name                = "${var.name_prefix}-ac-nsg-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  security_rule {
    name                       = "SSH_VNET"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "OUTBOUND"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = local.global_tags
}

resource "azurerm_network_interface" "ac_nic" {
  count               = var.ac_count
  name                = "${var.name_prefix}-ac-nic-${count.index + 1}-${local.resource_tag}"
  location            = var.arm_location
  resource_group_name = module.network.resource_group_name

  ip_configuration {
    name                          = "ac-ip-config"
    subnet_id                     = azurerm_subnet.ac.id
    private_ip_address_allocation = "Dynamic"
  }

  tags = local.global_tags
}

resource "azurerm_network_interface_security_group_association" "ac_nic_nsg" {
  count                     = var.ac_count
  network_interface_id      = azurerm_network_interface.ac_nic[count.index].id
  network_security_group_id = azurerm_network_security_group.ac_nsg.id
}

resource "azurerm_linux_virtual_machine" "ac" {
  count                 = var.ac_count
  name                  = "${var.name_prefix}-ac-vm-${count.index + 1}-${local.resource_tag}"
  location              = var.arm_location
  resource_group_name   = module.network.resource_group_name
  network_interface_ids = [azurerm_network_interface.ac_nic[count.index].id]
  size                  = var.acvm_instance_type
  admin_username        = var.ac_admin_username

  identity {
    type         = "UserAssigned"
    identity_ids = [module.cc_identity.managed_identity_id]
  }

  admin_ssh_key {
    username   = var.ac_admin_username
    public_key = "${trimspace(tls_private_key.key.public_key_openssh)} ${var.ac_admin_username}@me.io"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = var.acvm_image_publisher
    offer     = var.acvm_image_offer
    sku       = var.acvm_image_sku
    version   = var.acvm_image_version
  }

  plan {
    publisher = var.acvm_image_publisher
    name      = var.acvm_image_sku
    product   = var.acvm_image_offer
  }

  custom_data = base64encode(<<-ACDATA
#!/bin/bash
systemctl stop zpa-connector 2>/dev/null || true
echo "${zpa_provisioning_key.app_connector_provisioning_key.provisioning_key}" > /opt/zscaler/var/provision_key
chmod 644 /opt/zscaler/var/provision_key
systemctl start zpa-connector
ACDATA
  )

  tags = local.global_tags

  depends_on = [
    azurerm_network_interface.ac_nic,
    azurerm_network_interface_security_group_association.ac_nic_nsg,
    azurerm_marketplace_agreement.ac_image
  ]
}

################################################################################
# 8. Guacamole user-mapping.xml + SCP to bastion
################################################################################
locals {
  usermapping = <<UM
<user-mapping>
<authorize
username="cloudconnector"
password="8b4feec7f41e1c157701fc950372a8a2"
encoding="md5">

<!-- ===== Azure Workloads ===== -->
<connection name="Azure Workload 1 (RDP)">
  <protocol>rdp</protocol>
  <param name="hostname">${azurerm_linux_virtual_machine.workload[0].private_ip_address}</param>
  <param name="port">3389</param>
  <param name="username">${var.workload_admin_username}</param>
  <param name="password">CloudConnector2022!</param>
  <param name="ignore-cert">true</param>
  <param name="security">rdp</param>
</connection>
<connection name="Azure Workload 1 (SSH)">
  <protocol>ssh</protocol>
  <param name="hostname">${azurerm_linux_virtual_machine.workload[0].private_ip_address}</param>
  <param name="port">22</param>
  <param name="username">${var.workload_admin_username}</param>
  <param name="private-key">${tls_private_key.key.private_key_pem}</param>
</connection>
<connection name="Azure Workload 2 (RDP)">
  <protocol>rdp</protocol>
  <param name="hostname">${azurerm_linux_virtual_machine.workload[1].private_ip_address}</param>
  <param name="port">3389</param>
  <param name="username">${var.workload_admin_username}</param>
  <param name="password">CloudConnector2022!</param>
  <param name="ignore-cert">true</param>
  <param name="security">rdp</param>
</connection>
<connection name="Azure Workload 2 (SSH)">
  <protocol>ssh</protocol>
  <param name="hostname">${azurerm_linux_virtual_machine.workload[1].private_ip_address}</param>
  <param name="port">22</param>
  <param name="username">${var.workload_admin_username}</param>
  <param name="private-key">${tls_private_key.key.private_key_pem}</param>
</connection>
<connection name="Azure App Connector (SSH)">
  <protocol>ssh</protocol>
  <param name="hostname">${azurerm_network_interface.ac_nic[0].private_ip_address}</param>
  <param name="port">22</param>
  <param name="username">${var.ac_admin_username}</param>
  <param name="private-key">${tls_private_key.key.private_key_pem}</param>
</connection>
</authorize>
</user-mapping>
UM

  bastion_ssh_info = <<BC
${azurerm_public_ip.bastion_pip.ip_address}/32
BC
}


################################################################################
# 9. Per-pod DNS CNAME to Application Gateway
################################################################################
resource "azurerm_dns_cname_record" "bastion" {
  count               = var.deploy_public_endpoint ? 1 : 0
  name                = "pod-${local.resource_tag}"
  zone_name           = var.lab_domain
  resource_group_name = var.dns_zone_resource_group_name
  ttl                 = 300
  record              = azurerm_public_ip.appgw_pip[0].fqdn

  tags = local.global_tags
}
