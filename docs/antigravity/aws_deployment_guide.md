# Deploying Mifos Gazelle on AWS

This guide outlines the steps to deploy Mifos Gazelle (all components) on an AWS EC2 instance.

## 1. Launch EC2 Instance

### Instance Specifications
-   **OS**: Ubuntu 22.04 LTS or 24.04 LTS
-   **Architecture**: x86_64 (Intel/AMD) recommended, or ARM64 (Graviton)
-   **Instance Type**:
    -   Minimum: `t3.2xlarge` (8 vCPU, 32 GiB RAM) is recommended to satisfy the 24GB+ RAM requirement comfortably.
    -   Standard: `r6i.xlarge` (4 vCPU, 32 GiB RAM) is also a good memory-optimized choice.
-   **Storage**: 50 GB+ gp3 root volume.

### Security Group (Inbound Rules)
Open the following ports to your IP (or `0.0.0.0/0` for public testing, but be careful):

| Port | Protocol | Purpose |
| :--- | :--- | :--- |
| `22` | TCP | SSH Access |
| `80` | TCP | Ingress (Main entry) |
| `443` | TCP | Ingress (SSL) |
| `6443` | TCP | Kubernetes API (Optional, for remote kubectl) |

## 2. Configuration & Installation

Connect to your instance via SSH:
```bash
ssh -i key.pem ubuntu@<public-ip>
```

### Install Prerequisites & Clone Repo
```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Clone Repository
git clone https://github.com/openMF/mifos-gazelle.git
cd mifos-gazelle

# (Optional) Checkout the specific tag if needed, otherwise use master/dev
git checkout master
```

### Run the Installer
Run the deployment script. This handles K3s installation, Helm charts, and app deployment:
```bash
# Deploy all components (MifosX, vNext, PHEE)
sudo ./run.sh -u ubuntu -m deploy -a all
```
*Note: This process takes ~15-20 minutes.*

## 3. Accessing the Application

Mifos Gazelle uses **local domain names** (e.g., `mifos.mifos.gazelle.test`) which resolve via the Ingress controller on the VM. Since these aren't real public DNS records, you must configure your local machine to map these domains to the **AWS Public IP**.

### Update Local Hosts File
On your local machine (laptop/desktop):
-   **Windows**: `C:\Windows\System32\drivers\etc\hosts`
-   **Mac/Linux**: `/etc/hosts`

Add the following lines (replace `<AWS-PUBLIC-IP>` with the actual IP):

```text
<AWS-PUBLIC-IP> mifos.mifos.gazelle.test
<AWS-PUBLIC-IP> fineract.mifos.gazelle.test
<AWS-PUBLIC-IP> vnextadmin.mifos.gazelle.test
<AWS-PUBLIC-IP> ops.mifos.gazelle.test
<AWS-PUBLIC-IP> zeebe-operate.mifos.gazelle.test
```

### Verify Access
Open your browser and visit:
-   **MifosX**: [http://mifos.mifos.gazelle.test](http://mifos.mifos.gazelle.test) (User: `mifos`, Pass: `password`)
-   **Payment Hub Ops**: [http://ops.mifos.gazelle.test](http://ops.mifos.gazelle.test)
-   **Camunda Operate**: [http://zeebe-operate.mifos.gazelle.test](http://zeebe-operate.mifos.gazelle.test) (User: `demo`, Pass: `demo`)

## 4. Troubleshooting on AWS

If pods fail to start:
1.  **Check Memory**: Ensure the instance actually has 24GB+ RAM available (`free -h`).
2.  **Check Pods**:
    ```bash
    # Install k9s for easy monitoring
    ./src/utils/install-k9s.sh
    ~/local/bin/k9s
    ```
3.  **Zeebe Issues**: If restarting, remember to check `zeebe-gateway` status as identified in previous debugging.
4. **Public IP Changes**: If you stop/start the instance, the Public IP changes. You must update your local `hosts` file again. Use an Elastic IP (EIP) to prevent this.
