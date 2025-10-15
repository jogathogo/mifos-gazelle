# Mifos Gazelle - macOS Setup Guide

## Overview
The Mifos Gazelle deployment scripts have been updated to support both **Ubuntu 24.04** and **macOS**. The scripts automatically detect your operating system and use the appropriate commands.

## Key Changes for macOS Compatibility

### 1. **OS Detection**
All scripts now detect the operating system at startup:
```bash
OS_TYPE="$(uname -s)"
case "${OS_TYPE}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
esac
```

### 2. **User Switching**
- **Linux**: Uses `su - $k8s_user -c "command"`
- **macOS**: Uses `sudo -u "$k8s_user" command` or `sudo -u "$k8s_user" bash -c "command"`

### 3. **Kubernetes Distribution**
- **Linux**: Supports k3s or microk8s
- **macOS**: Uses k3d (k3s in Docker) - automatically installed via Homebrew

### 4. **Package Management**
- **Linux**: Uses `apt-get`, `snap`, `curl`
- **macOS**: Uses Homebrew (`brew`)

### 5. **Command Differences**
- **wc -l**: Added `tr -d ' '` to remove leading spaces on macOS
- **mktemp -d**: Uses `mktemp -d -t prefix` on macOS
- **Memory check**: `sysctl -n hw.memsize` on macOS vs `free -g` on Linux
- **Disk space**: `df -g` on macOS vs `df -BG` on Linux

## Prerequisites for macOS

### Required Software
```bash
# Install Homebrew if not present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install required tools
brew install kubectl
brew install helm
brew install jq
brew install k3d
brew install git
brew install --cask docker

# Install crudini (via pip3)
pip3 install crudini
```

### Docker Desktop
1. Install Docker Desktop for Mac
2. Start Docker Desktop
3. Ensure it's running before deploying
4. Allocate at least 8GB RAM in Docker Desktop preferences

## Installation Steps

### 1. Clone the Repository
```bash
cd ~
git clone <your-mifos-gazelle-repo-url>
cd mifos-gazelle
```

### 2. Set Up Directory Structure
```bash
mkdir -p ~/mifos-gazelle/apps
mkdir -p ~/mifos-gazelle/config
chmod +x run.sh
```

### 3. Review Configuration File
Edit `config/config.ini` to set your preferences:
```ini
[general]
mode = deploy
GAZELLE_DOMAIN = mifos.gazelle.test

[environment]
user = $USER  # Will expand to your macOS username

[infra]
enabled = true

[vnext]
enabled = true

[phee]
enabled = true

[mifosx]
enabled = true
```

### 4. Run the Deployment
```bash
# Deploy all components
sudo ./run.sh -m deploy -u $USER -v 1.33

# Deploy specific components
sudo ./run.sh -m deploy -u $USER -v 1.33 -a "infra,mifosx"

# Deploy with debug mode
sudo ./run.sh -m deploy -u $USER -v 1.33 -d true

# Use custom config file
sudo ./run.sh -f /path/to/custom-config.ini -m deploy -u $USER -v 1.33
```

## macOS-Specific Behaviors

### Kubernetes Cluster
- **Automatic**: Scripts automatically use k3d (containerized k3s) on macOS
- **Cluster Name**: `mifos-cluster`
- **Port Mapping**: HTTP (80) and HTTPS (443) automatically mapped

### Shell Configuration
- Scripts detect and configure **zsh** (default on modern macOS) or **bash**
- Configuration added to `~/.zshrc` or `~/.bashrc`

### File Permissions
- Uses `sudo` for system-level operations
- User files remain owned by your macOS user
- More permissive than Linux (handles permission errors gracefully)

### Host File Updates
- Requires `sudo` to modify `/etc/hosts`
- Automatically adds all required *.mifos.gazelle.test domains

## Command Reference

### Deploy Commands
```bash
# Full deployment
sudo ./run.sh -m deploy -u $USER -v 1.33 -a all

# Individual components
sudo ./run.sh -m deploy -u $USER -v 1.33 -a infra
sudo ./run.sh -m deploy -u $USER -v 1.33 -a vnext
sudo ./run.sh -m deploy -u $USER -v 1.33 -a phee
sudo ./run.sh -m deploy -u $USER -v 1.33 -a mifosx

# Multiple components
sudo ./run.sh -m deploy -u $USER -v 1.33 -a "vnext,mifosx"
```

### Cleanup Commands
```bash
# Remove apps only (keep cluster)
sudo ./run.sh -m cleanapps -u $USER -a all

# Remove specific apps
sudo ./run.sh -m cleanapps -u $USER -a "mifosx,vnext"

# Remove everything (apps + cluster)
sudo ./run.sh -m cleanall -u $USER
```

### Verification Commands
```bash
# Check cluster status
kubectl cluster-info
kubectl get nodes

# Check deployments
kubectl get pods -n vnext
kubectl get pods -n paymenthub
kubectl get pods -n mifosx
kubectl get pods -n infra

# Check all namespaces
kubectl get pods --all-namespaces

# Use k9s (if installed)
k9s
```

## Troubleshooting

### Issue: "kubectl: command not found"
```bash
# Install kubectl
brew install kubectl

# Verify installation
kubectl version --client
```

### Issue: "helm: command not found"
```bash
# Install helm
brew install helm

# Verify installation
helm version
```

### Issue: "Docker is not running"
```bash
# Start Docker Desktop manually
open -a Docker

# Wait for Docker to start, then retry deployment
```

### Issue: "Cannot connect to k3d cluster"
```bash
# Check if cluster exists
k3d cluster list

# Recreate cluster if needed
k3d cluster delete mifos-cluster
k3d cluster create mifos-cluster --servers 1 --agents 2

# Update kubeconfig
k3d kubeconfig get mifos-cluster > ~/.kube/config
```

### Issue: "Permission denied" errors
```bash
# Ensure you're using sudo
sudo ./run.sh -m deploy -u $USER -v 1.33

# Check file permissions
ls -la run.sh
chmod +x run.sh
```

### Issue: "crudini not found"
```bash
# Install Python 3 if needed
brew install python3

# Install crudini
pip3 install crudini

# Verify installation
crudini --version
```

### Issue: Pods not starting
```bash
# Check pod status
kubectl get pods -n <namespace>

# Describe problematic pod
kubectl describe pod <pod-name> -n <namespace>

# Check logs
kubectl logs <pod-name> -n <namespace>

# Check Docker Desktop resources
# Go to Docker Desktop > Preferences > Resources
# Increase CPUs to 4+ and Memory to 8GB+
```

### Issue: "/etc/hosts" not updating
```bash
# Manually verify hosts entries
cat /etc/hosts | grep gazelle

# Manually add if needed (requires sudo)
sudo nano /etc/hosts
# Add all *.mifos.gazelle.test entries pointing to 127.0.0.1
```

## Differences from Ubuntu Deployment

| Feature | Ubuntu | macOS |
|---------|--------|-------|
| K8s Distribution | k3s or microk8s | k3d (k3s in Docker) |
| User Switching | `su -` | `sudo -u` |
| Package Manager | apt/snap | Homebrew |
| Shell | bash | zsh (default) or bash |
| Memory Check | `free -g` | `sysctl hw.memsize` |
| Temp Directories | `mktemp -d` | `mktemp -d -t prefix` |
| k9s Installation | Automatic | Manual (`brew install k9s`) |

## Performance Considerations

### macOS Limitations
- **Docker Desktop overhead**: Additional resource usage compared to native Linux
- **File I/O**: Slightly slower due to Docker volume mounts
- **Network**: May require additional port forwarding configuration

### Recommended Resources
- **RAM**: 16GB minimum (8GB for Docker Desktop)
- **CPU**: 4+ cores
- **Disk**: 50GB+ free space
- **Docker Desktop Settings**:
  - CPUs: 4-6
  - Memory: 8-10GB
  - Swap: 2GB

## Testing Your Deployment

### 1. Check Cluster Health
```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

### 2. Access Web Interfaces
After deployment, access these URLs in your browser:
- MifosX: http://mifos.mifos.gazelle.test
- Fineract: http://fineract.mifos.gazelle.test
- vNext Admin: http://vnextadmin.mifos.gazelle.test
- PaymentHub Ops: http://ops.mifos.gazelle.test

### 3. Run Health Checks
```bash
# Check ingress
kubectl get ingress --all-namespaces

# Check services
kubectl get svc --all-namespaces

# Check persistent volumes
kubectl get pv
kubectl get pvc --all-namespaces
```

## Uninstallation

### Remove Everything
```bash
# Complete cleanup
sudo ./run.sh -m cleanall -u $USER

# Manual k3d cleanup if needed
k3d cluster delete mifos-cluster

# Remove configuration from shell
nano ~/.zshrc  # or ~/.bashrc
# Remove lines between GAZELLE_START and GAZELLE_END
```

### Remove Just Applications
```bash
# Keep cluster, remove apps
sudo ./run.sh -m cleanapps -u $USER -a all
```

## Getting Help

### Enable Debug Mode
```bash
sudo ./run.sh -m deploy -u $USER -v 1.33 -d true
```

### Check Logs
```bash
# Deployment logs are printed to stdout
# Redirect to file for analysis
sudo ./run.sh -m deploy -u $USER -v 1.33 2>&1 | tee deployment.log
```

### Common Issues Log Location
- kubectl logs: `kubectl logs <pod> -n <namespace>`
- k3d logs: `k3d cluster list` and `docker logs <container>`
- System logs: `/var/log/system.log` (macOS)

## Next Steps

After successful deployment:
1. Configure your applications via web interfaces
2. Set up monitoring with k9s: `brew install k9s && k9s`
3. Review security settings
4. Configure backups for persistent data
5. Explore the deployed applications

## Support

For issues specific to macOS deployment:
1. Check Docker Desktop is running
2. Verify all prerequisites are installed
3. Review the troubleshooting section
4. Enable debug mode for detailed output
5. Check GitHub issues for known problems