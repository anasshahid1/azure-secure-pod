# Azure Secure Lab Pod

Single-region Azure port of the AWS `zscaler-secure-pod` lab.
Deploys a Guacamole bastion fronted by **Azure Application Gateway + Azure DNS**,
Zscaler Cloud Connectors in **VMSS**, and a ZPA App Connector VM.

## Architecture

```
Student browser
      │ HTTPS :443 (Key Vault wildcard cert)
      ▼
Azure DNS  ──►  Application Gateway  ──►  Bastion VM :8080 (Guacamole)
                                              │
                                              ▼
                                          guacd  ──►  Workload VMs (SSH, private IP)
```

## Resources deployed per pod

- Azure DNS zone and wildcard Key Vault certificate created once in `bootstrap/`.
- Per-pod Resource Group, VNet, subnets (CC, workload, bastion, App Gateway, Private DNS, AC).
- Application Gateway v2 with HTTPS listener + HTTP to HTTPS redirect.
- Guacamole bastion VM (Ubuntu + Docker Guacamole). `user-mapping.xml` is SCP'd after apply.
- Workload VMs (Ubuntu + xrdp/xfce4 for RDP and SSH).
- Cloud Connector VMSS behind an internal Azure Load Balancer.
- Azure Function App for Cloud Connector VMSS lifecycle and health monitoring.
- Azure Private DNS Resolver for ZPA DNS redirection.
- ZPA App Connector Group + Provisioning Key + AC VM in a dedicated peered VNet.
- Per-pod CNAME `pod-<suffix>.<lab_domain>` to the Application Gateway public IP.

## Prerequisites

- Terraform 1.5+
- `az login` with a Subscription Contributor or equivalent role.
- An Azure DNS zone apex domain (e.g. `ztcloudlab.com`) registered at your registrar.
- A pre-created **User Assigned Managed Identity** for Cloud Connector with:
  - `Network Contributor` on the target resource group
  - `Get`, `List` secrets access on the per-pod Key Vault (Terraform will add this policy)
- Marketplace terms accepted for the Zscaler Cloud Connector image:
  ```bash
  az vm image terms accept --urn zscaler1579058425289:zia_cloud_connector:zs_ser_gen1_cc_01:latest
  ```

## One-Time Bootstrap

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit lab_domain / arm_location if needed
terraform init
terraform apply
```

When finished, delegate your registrar's NS records to the `dns_zone_name_servers` output.

Capture:

- `lab_domain`
- `dns_zone_resource_group_name`
- `wildcard_cert_secret_id`

## Deploy a Pod

```bash
cd ..
cp terraform.tfvars.example terraform.tfvars   # fill in all values
terraform init
terraform apply
```

Final output:

```
lab_url = "https://pod-pod1.ztcloudlab.com/"
```

## Destroy

```bash
terraform destroy
```

## Caveats / Follow-ups

- **Guacamole image**: the bastion cloud-init installs the official `guacamole/guacamole` and `guacamole/guacd` Docker images plus the `guacamole-auth-file` extension. The `user-mapping.xml` is copied to `/etc/guacamole` and the container restarted.
- **ZPA App Connector VM**: uses the Zscaler Azure Marketplace image in a dedicated VNet peered to the CC/workload VNet. Set `accept_marketplace_agreement = true` only on the first deploy in a new subscription, or accept the terms beforehand with `az vm image terms accept --urn zscaler:zscaler-private-access:zpa-con-azure:latest`.
- **Function App**: the Function App is deployed but `run_manual_sync` is disabled to avoid a local script dependency. After the first `apply`, open the Function App in the Azure Portal once to trigger the zip sync, or re-run with `run_manual_sync = true` if running from a local clone.
- The upstream Zscaler Azure modules are pulled directly from GitHub `main`. Pin the `ref=` in `main.tf` to a specific commit/tag for reproducibility.
- This is single-region. A 2-region variant would use aliased `azurerm` providers.
