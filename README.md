# Azure Secure Lab Pod

A single-region Azure port of the AWS `zscaler-secure-pod` lab environment. It deploys a Guacamole bastion, Zscaler Cloud Connectors in a VMSS, a ZPA App Connector, and demo Ubuntu workloads -- all accessible through a public endpoint.

---

## What it deploys

- Azure Resource Group, VNet, and purpose-built subnets (CC, workload, bastion, Private DNS, App Gateway, AC).
- Guacamole bastion VM (Ubuntu + Docker Guacamole) with a pre-built `user-mapping.xml`.
- Workload VMs with `xrdp` / `xfce4` for RDP and SSH access.
- Cloud Connector VMSS behind an internal Azure Load Balancer.
- Azure Function App for Cloud Connector lifecycle/health monitoring.
- Azure Private DNS Resolver for ZPA DNS redirection.
- ZPA App Connector Group + Provisioning Key + AC VM in a dedicated peered VNet.
- Optional Application Gateway v2 with HTTPS listener, DNS CNAME, and Key Vault wildcard certificate.

---

## Architecture

### Default mode: direct Guacamole on the bastion public IP

```
Student browser
      │ HTTP :8080
      ▼
Bastion VM (Guacamole) ──► guacd ──► Workload VMs (RDP/SSH, private IP)
      │
      ▼
Cloud Connector VMSS ──► Zscaler Cloud
```

### Optional mode: public HTTPS via Application Gateway

```
Student browser
      │ HTTPS :443
      ▼
Azure DNS ──► Application Gateway ──► Bastion VM :8080 (Guacamole)
                                            │
                                            ▼
                                        guacd ──► Workload VMs (RDP/SSH)
```

Set `deploy_public_endpoint = true` to enable the Application Gateway + DNS path. This requires the one-time `bootstrap/` outputs.

---

## Repository layout

```
.
├── bootstrap/                 # One-time shared infrastructure (DNS zone + Key Vault cert)
│   ├── main.tf
│   ├── terraform.tfvars.example
│   └── outputs.tf
├── main.tf                    # Per-pod deployment
├── variables.tf
├── output.tf
├── terraform.tfvars.example   # Copy to terraform.tfvars and fill in
├── versions.tf
└── README.md                  # This file
```

---

## Prerequisites

1. **Terraform** 1.5+ installed.
2. **Azure CLI** authenticated (`az login`) with permissions to create resources in the target subscription.
3. A registered DNS apex domain for the optional HTTPS path (e.g. `ztcloudlab.com`).
4. A pre-created **User Assigned Managed Identity** for Cloud Connector.
   - Resource group and name known (e.g. `AS-CC-MI` in `AS-CC-RG-TF`).
   - Must have `Network Contributor` on the target resource group.
   - Must have `Get` and `List` secret permissions on the Key Vault that stores CC credentials.
5. Zscaler Cloud Connector marketplace terms accepted in the subscription (run once):
   ```bash
   az vm image terms accept \
     --urn zscaler1579058425289:zia_cloud_connector:zs_ser_gen1_cc_01:latest
   ```
6. Sufficient Azure vCPU quota for the chosen region/VM size (default is `Standard_D2s_v3`).

---

## One-time bootstrap

The `bootstrap/` stack creates the shared DNS zone and a Key Vault wildcard certificate used when `deploy_public_endpoint = true`.

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your lab_domain, arm_location, etc.
terraform init
terraform apply
```

When complete, delegate your registrar's NS records to the `dns_zone_name_servers` output. Capture the outputs for the per-pod deployment:

- `lab_domain`
- `dns_zone_resource_group_name`
- `wildcard_cert_secret_id`

---

## Deploy a pod

### 1. Configure variables

```bash
cd ..
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at minimum:

```hcl
env_subscription_id = "00000000-0000-0000-0000-000000000000"
arm_location        = "eastus2"
name_suffix         = "pod1"

# Lab credentials -- change these!
workload_admin_password  = "ChangeMe2024!"
guacamole_admin_password = "ChangeMe2024!"

lab_domain                   = "ztcloudlab.com"
dns_zone_resource_group_name = "zscc-bootstrap-..."
wildcard_cert_secret_id      = "https://<vault>.vault.azure.net/secrets/wildcard-.../..."

cc_vm_prov_url  = "connector.zscloud.net/api/v1/provUrl?name=Azure-Prod"
secret_username = "your_cc_user@example.com"
secret_password = "your_cc_password"
secret_apikey   = "your_partner_api_key"

cc_vm_managed_identity_name = "AS-CC-MI"
cc_vm_managed_identity_rg   = "AS-CC-RG-TF"

zpa_client_id     = "..."
zpa_client_secret = "..."
zpa_customer_id   = "..."

# Optional: tighten access to your own IP
bastion_nsg_source_prefix = "YOUR_PUBLIC_IP/32"
```

> **Security note:** `terraform.tfvars` contains secrets and is already ignored by `.gitignore`. Never commit it.

### 2. Initialize and apply

```bash
terraform init
terraform apply
```

### 3. Collect outputs

For the default deployment:

```
lab_url = "http://20.x.x.x:8080/guacamole/"
```

For the public HTTPS deployment:

```
lab_url = "https://pod-pod1.ztcloudlab.com/"
```

---

## Accessing the lab

### Guacamole

- **URL**: from `lab_url` output.
- **Guacamole login**: `cloudconnector` / `<guacamole_admin_password>` from `terraform.tfvars`
- The `user-mapping.xml` exposes:
  - Workload 1 / Workload 2 (RDP and SSH)
  - ZPA App Connector (SSH)

### Workload access

- **RDP username**: `cloudconnector`
- **RDP password**: `<workload_admin_password>` from `terraform.tfvars`
- **SSH username**: `cloudconnector` (keypair is written locally; keep it secure)

### Bastion SSH

- **Username**: `ubuntu`
- **Auth**: the generated `.pem` private key file (ignored by Git).

### Cloud Connector registration

After `terraform apply` succeeds:

1. Verify the `AS-CC-MI` managed identity has `Get` / `List` secret permissions on the Key Vault used for CC credentials.
2. Verify the Key Vault contains the three secrets expected by the Cloud Connector image:
   - `username`
   - `password`
   - `api-key`
3. Wait **5-10 minutes**, then confirm the Cloud Connectors appear in the Zscaler Admin Console under **Administration > Cloud Connectors**.

### ZPA App Connector

After the AC VM is running, the App Connector should register to the ZPA App Connector Group created by Terraform. Verify in **Administration > App Connector Groups**.

---

## Cleanup

To destroy the pod resources:

```bash
terraform destroy
```

> This destroys the per-pod resource group. The shared `bootstrap/` resources and the pre-created managed identity / Key Vault are not removed.

---

## Security and cost considerations

- `bastion_nsg_source_prefix` defaults to `*`. For a lab, restrict it to your public IP or organization's egress range.
- The workload password is a lab default. Rotate it before any sensitive use.
- `terraform.tfstate` and generated `.pem` keys are ignored by `.gitignore`; do not force-add them.
- Cloud Connector VMSS, Application Gateway, and NAT Gateways incur ongoing cost. Destroy the pod when not in use.
- The upstream Zscaler modules are pulled from GitHub `main`. Pin the `ref=` values in `main.tf` to a specific tag or commit for reproducibility.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Guacamole URL does not load | NSG blocks port 8080 from your IP | Update `bastion_nsg_source_prefix` to your public IP |
| RDP connection shows "unreachable" | `xrdp` not installed on workloads | Workload outbound is routed through CC; temporarily enable outbound or re-run install |
| Cloud Connectors not in portal | MI missing Key Vault `Get/List` or secrets missing/wrong | Grant access policy and verify `username`, `password`, `api-key` secrets |
| ZPA AC not in portal | Provisioning key mismatch / AC NSG | Verify ZPA API credentials and VNet peering |
| `terraform apply` quota errors | vCPU limit in region | Request quota increase or pick another region |

---

## License

This is a lab/demo project. Use at your own risk and adapt to your organization's policies before production use.
