#!/bin/bash
# Dokploy Setup Script for Enterprise Homelab
# Creates and configures Dokploy instances for dev, staging, and production environments

set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/config/homelab.conf"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $1"
}

# Load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    else
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Set IP variables based on network mode
    if [[ "$NETWORK_MODE" == "vlan" ]]; then
        DOKPLOY_DEV_IP="${VLAN_DOKPLOY_DEV_IP}"
        DOKPLOY_STAGING_IP="${VLAN_DOKPLOY_STAGING_IP}"
        DOKPLOY_PROD_IP="${VLAN_DOKPLOY_PROD_IP}"
        QNAP_HOST_IP="${VLAN_QNAP_IP}"
        DEV_BRIDGE="vmbr30"
        STAGING_BRIDGE="vmbr40"
        PROD_BRIDGE="vmbr50"
        DEV_GATEWAY="${VLAN_DOKPLOY_DEV_IP%.*}.1"
        STAGING_GATEWAY="${VLAN_DOKPLOY_STAGING_IP%.*}.1"
        PROD_GATEWAY="${VLAN_DOKPLOY_PROD_IP%.*}.1"
    else
        DOKPLOY_DEV_IP="${DOKPLOY_DEV_IP}"
        DOKPLOY_STAGING_IP="${DOKPLOY_STAGING_IP}"
        DOKPLOY_PROD_IP="${DOKPLOY_PROD_IP}"
        QNAP_HOST_IP="${QNAP_IP}"
        DEV_BRIDGE="vmbr0"
        STAGING_BRIDGE="vmbr0"
        PROD_BRIDGE="vmbr0"
        DEV_GATEWAY="${GATEWAY_IP}"
        STAGING_GATEWAY="${GATEWAY_IP}"
        PROD_GATEWAY="${GATEWAY_IP}"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if VM template exists
    if ! qm status 9000 &> /dev/null; then
        log_error "VM template 9000 (dokploy-template) not found"
        log_info "Run the main installation script first to create the template"
        exit 1
    fi
    
    # Check available storage
    local available_space=$(pvesm status local-lvm | awk 'NR==2 {print $3}')
    local available_gb=$((available_space / 1024 / 1024 / 1024))
    
    if [[ $available_gb -lt 50 ]]; then
        log_error "Insufficient storage space. Required: 50GB, Available: ${available_gb}GB"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Create Dokploy VM
create_dokploy_vm() {
    local env=$1
    local vmid=$2
    local memory_gb=$3
    local cpu_cores=$4
    local disk_size_gb=$5
    local ip_address=$6
    local bridge=$7
    local gateway=$8
    
    log_progress "Creating Dokploy VM for $env environment..."
    
    # Check if VM already exists
    if qm status $vmid &> /dev/null; then
        log_warning "VM $vmid already exists"
        return 0
    fi
    
    # Clone from template
    log_info "Cloning VM from template 9000..."
    qm clone 9000 $vmid --name "dokploy-$env" --full --storage local-lvm
    
    # Configure VM resources
    log_info "Configuring VM resources..."
    qm set $vmid \
        --memory $((memory_gb * 1024)) \
        --cores $cpu_cores \
        --net0 "virtio,bridge=$bridge" \
        --ipconfig0 "ip=$ip_address/24,gw=$gateway" \
        --nameserver "${ADGUARD_PRIMARY_IP:-192.168.1.20}" \
        --searchdomain "lab.local" \
        --onboot 1 \
        --protection 0 \
        --description "Dokploy $env environment - Container orchestration platform"
    
    # Resize disk
    log_info "Expanding disk to ${disk_size_gb}GB..."
    qm resize $vmid scsi0 +${disk_size_gb}G
    
    # Set cloud-init password
    if [[ -n "${DOKPLOY_ADMIN_PASSWORD:-}" ]]; then
        qm set $vmid --cipassword $(openssl passwd -6 "$DOKPLOY_ADMIN_PASSWORD")
    fi
    
    log_success "VM $vmid created for $env environment"
}

# Start VM and wait for readiness
start_and_wait_vm() {
    local vmid=$1
    local env=$2
    local ip_address=$3
    
    log_progress "Starting VM $vmid ($env)..."
    
    # Start VM
    qm start $vmid
    
    # Wait for VM to be running
    log_info "Waiting for VM to start..."
    for i in {1..60}; do
        if qm status $vmid | grep -q "running"; then
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_error "VM $vmid failed to start within 10 minutes"
            return 1
        fi
        sleep 10
    done
    
    # Wait for cloud-init to complete and SSH to be available
    log_info "Waiting for cloud-init and SSH connectivity..."
    for i in {1..120}; do
        if nc -z $ip_address 22 2>/dev/null; then
            log_success "SSH connectivity established to $ip_address"
            break
        fi
        if [[ $i -eq 120 ]]; then
            log_error "SSH timeout for $ip_address after 20 minutes"
            return 1
        fi
        sleep 10
    done
    
    # Additional wait for cloud-init to fully complete
    log_info "Waiting for cloud-init to complete..."
    sleep 60
    
    log_success "VM $vmid is ready"
}

# Install Docker and dependencies
install_docker() {
    local ip_address=$1
    local env=$2
    
    log_progress "Installing Docker on $env environment..."
    
    # Create installation script
    cat > /tmp/install-docker-${env}.sh << 'DOCKER_EOF'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# Update system
sudo apt update
sudo apt upgrade -y

# Install dependencies
sudo apt install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    vim \
    htop \
    net-tools \
    dnsutils \
    unzip \
    git \
    jq \
    nfs-common

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

# Add user to docker group
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Configure Docker daemon
sudo mkdir -p /etc/docker
cat << 'DAEMON_EOF' | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "dns": ["192.168.1.20", "192.168.1.21"],
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    }
  ]
}
DAEMON_EOF

# Restart Docker to apply configuration
sudo systemctl restart docker

echo "Docker installation completed"
DOCKER_EOF
    
    # Copy and execute script
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 /tmp/install-docker-${env}.sh ubuntu@$ip_address:/tmp/
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 ubuntu@$ip_address "chmod +x /tmp/install-docker-${env}.sh && /tmp/install-docker-${env}.sh"
    
    # Clean up
    rm /tmp/install-docker-${env}.sh
    
    log_success "Docker installed on $env environment"
}

# Configure shared storage
configure_shared_storage() {
    local ip_address=$1
    local env=$2
    
    log_progress "Configuring shared storage for $env environment..."
    
    # Create storage configuration script
    cat > /tmp/configure-storage-${env}.sh << 'STORAGE_EOF'
#!/bin/bash
set -e

# Create mount point for shared storage
sudo mkdir -p /mnt/shared-storage
sudo mkdir -p /mnt/dokploy-data

# Add NFS mount to fstab (commented out initially)
echo "# QNAP NFS mount for Dokploy shared storage" | sudo tee -a /etc/fstab
echo "# Configure after QNAP setup is complete" | sudo tee -a /etc/fstab

# Create Docker volumes directory structure
sudo mkdir -p /var/lib/docker/volumes
sudo mkdir -p /opt/dokploy

# Set up environment-specific directories
sudo mkdir -p /opt/dokploy/shared
sudo mkdir -p /opt/dokploy/backups
sudo mkdir -p /opt/dokploy/configs

# Set proper ownership
sudo chown -R ubuntu:ubuntu /opt/dokploy
sudo chown ubuntu:docker /var/lib/docker/volumes

echo "Storage configuration completed"
echo "Note: Configure QNAP NFS mount manually after QNAP setup"
STORAGE_EOF
    
    # Copy and execute script
    scp -o StrictHostKeyChecking=no /tmp/configure-storage-${env}.sh ubuntu@$ip_address:/tmp/
    ssh -o StrictHostKeyChecking=no ubuntu@$ip_address "chmod +x /tmp/configure-storage-${env}.sh && /tmp/configure-storage-${env}.sh"
    
    # Clean up
    rm /tmp/configure-storage-${env}.sh
    
    log_success "Shared storage configured for $env environment"
}

# Install Dokploy
install_dokploy() {
    local ip_address=$1
    local env=$2
    
    log_progress "Installing Dokploy on $env environment..."
    
    # Create Dokploy installation script
    cat > /tmp/install-dokploy-${env}.sh << 'DOKPLOY_EOF'
#!/bin/bash
set -e

# Install Dokploy
curl -sSL https://dokploy.com/install.sh | sh

# Wait for Dokploy to start
echo "Waiting for Dokploy to initialize..."
sleep 30

# Check if Dokploy is running
if docker ps | grep -q dokploy; then
    echo "Dokploy installed and running successfully"
else
    echo "Dokploy installation may have issues, checking logs..."
    docker logs dokploy || true
fi

# Create Dokploy service for auto-start
sudo systemctl enable docker
sudo systemctl enable dokploy || true

echo "Dokploy installation completed"
echo "Access the web interface at: http://$(hostname -I | awk '{print $1}'):3000"
DOKPLOY_EOF
    
    # Copy and execute script
    scp -o StrictHostKeyChecking=no /tmp/install-dokploy-${env}.sh ubuntu@$ip_address:/tmp/
    ssh -o StrictHostKeyChecking=no ubuntu@$ip_address "chmod +x /tmp/install-dokploy-${env}.sh && /tmp/install-dokploy-${env}.sh"
    
    # Clean up
    rm /tmp/install-dokploy-${env}.sh
    
    log_success "Dokploy installed on $env environment"
}

# Configure Dokploy environment
configure_dokploy_environment() {
    local ip_address=$1
    local env=$2
    
    log_progress "Configuring Dokploy environment settings for $env..."
    
    # Create environment configuration script
    cat > /tmp/configure-dokploy-${env}.sh << DOKPLOY_CONFIG_EOF
#!/bin/bash
set -e

# Create environment configuration file
mkdir -p /opt/dokploy/config

cat > /opt/dokploy/config/environment.env << 'ENV_EOF'
# Dokploy Environment Configuration - $env
ENVIRONMENT=$env
DOMAIN_SUFFIX=${DOMAIN_NAME}
LOCAL_DOMAIN=lab.local

# Resource limits
DEFAULT_CPU_LIMIT=${DEFAULT_CPU_LIMIT:-2}
DEFAULT_MEMORY_LIMIT=${DEFAULT_MEMORY_LIMIT:-2g}

# Storage configuration
SHARED_STORAGE_PATH=/mnt/shared-storage
DOCKER_VOLUMES_PATH=/var/lib/docker/volumes
BACKUP_PATH=/opt/dokploy/backups

# Networking
TRAEFIK_NETWORK=dokploy-network
DOCKER_NETWORK_SUBNET=172.20.0.0/16

# Security
ENABLE_HTTPS=true
AUTO_SSL=${ENABLE_SSL_AUTOMATION:-true}
FORCE_SSL=true

# Monitoring
ENABLE_METRICS=true
METRICS_PORT=9090

# Backup
ENABLE_BACKUPS=true
BACKUP_SCHEDULE=0 2 * * *
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
ENV_EOF

# Create Dokploy configuration override
cat > /opt/dokploy/config/dokploy.json << 'DOKPLOY_JSON_EOF'
{
  "environment": "$env",
  "features": {
    "monitoring": true,
    "backups": true,
    "ssl": true
  },
  "defaults": {
    "resources": {
      "cpu": "${DEFAULT_CPU_LIMIT:-2}",
      "memory": "${DEFAULT_MEMORY_LIMIT:-2g}"
    },
    "networks": {
      "default": "dokploy-network"
    }
  },
  "integrations": {
    "storage": {
      "type": "nfs",
      "path": "/mnt/shared-storage"
    },
    "monitoring": {
      "enabled": true,
      "endpoint": "http://${MONITORING_IP:-192.168.1.26}:9090"
    }
  }
}
DOKPLOY_JSON_EOF

# Set proper ownership
chown -R ubuntu:ubuntu /opt/dokploy/config

echo "Dokploy environment configuration completed for $env"
DOKPLOY_CONFIG_EOF
    
    # Copy and execute script
    scp -o StrictHostKeyChecking=no /tmp/configure-dokploy-${env}.sh ubuntu@$ip_address:/tmp/
    ssh -o StrictHostKeyChecking=no ubuntu@$ip_address "chmod +x /tmp/configure-dokploy-${env}.sh && /tmp/configure-dokploy-${env}.sh"
    
    # Clean up
    rm /tmp/configure-dokploy-${env}.sh
    
    log_success "Dokploy environment configured for $env"
}

# Validate Dokploy installation
validate_dokploy() {
    local ip_address=$1
    local env=$2
    
    log_progress "Validating Dokploy installation on $env environment..."
    
    # Check if Dokploy web interface is accessible
    if ! curl -f -s "http://$ip_address:3000" > /dev/null; then
        log_error "Dokploy web interface not accessible on $ip_address:3000"
        return 1
    fi
    
    # Check if Docker is running
    if ! ssh -o StrictHostKeyChecking=no ubuntu@$ip_address "docker ps" > /dev/null; then
        log_error "Docker not accessible on $env environment"
        return 1
    fi
    
    # Check if Dokploy container is running
    if ! ssh -o StrictHostKeyChecking=no ubuntu@$ip_address "docker ps | grep dokploy" > /dev/null; then
        log_error "Dokploy container not running on $env environment"
        return 1
    fi
    
    log_success "Dokploy validation passed for $env environment"
}

# Deploy environment
deploy_environment() {
    local env=$1
    local vmid=$2
    local memory_gb=$3
    local cpu_cores=$4
    local disk_size_gb=$5
    local ip_address=$6
    local bridge=$7
    local gateway=$8
    
    log_info "=== Deploying $env Environment ==="
    
    # Create VM
    create_dokploy_vm "$env" "$vmid" "$memory_gb" "$cpu_cores" "$disk_size_gb" "$ip_address" "$bridge" "$gateway"
    
    # Start VM and wait for readiness
    start_and_wait_vm "$vmid" "$env" "$ip_address"
    
    # Install Docker
    install_docker "$ip_address" "$env"
    
    # Configure shared storage
    configure_shared_storage "$ip_address" "$env"
    
    # Install Dokploy
    install_dokploy "$ip_address" "$env"
    
    # Configure environment
    configure_dokploy_environment "$ip_address" "$env"
    
    # Validate installation
    validate_dokploy "$ip_address" "$env"
    
    log_success "$env environment deployed successfully!"
}

# Generate deployment summary
generate_summary() {
    log_info "=== Dokploy Deployment Summary ==="
    echo ""
    echo "Development Environment:"
    echo "  - VM ID: 200"
    echo "  - IP Address: $DOKPLOY_DEV_IP"
    echo "  - Web Interface: http://$DOKPLOY_DEV_IP:3000"
    echo "  - Resources: ${DEV_CPU_LIMIT:-4} CPU, ${DEV_MEMORY_LIMIT:-8}GB RAM"
    echo ""
    echo "Staging Environment:"
    echo "  - VM ID: 201"
    echo "  - IP Address: $DOKPLOY_STAGING_IP"
    echo "  - Web Interface: http://$DOKPLOY_STAGING_IP:3000"
    echo "  - Resources: ${STAGING_CPU_LIMIT:-6} CPU, ${STAGING_MEMORY_LIMIT:-12}GB RAM"
    echo ""
    echo "Production Environment:"
    echo "  - VM ID: 202"
    echo "  - IP Address: $DOKPLOY_PROD_IP"
    echo "  - Web Interface: http://$DOKPLOY_PROD_IP:3000"
    echo "  - Resources: ${PROD_CPU_LIMIT:-8} CPU, ${PROD_MEMORY_LIMIT:-16}GB RAM"
    echo ""
    echo "Next Steps:"
    echo "1. Access each Dokploy web interface to complete initial setup"
    echo "2. Configure shared storage NFS mounts (after QNAP setup)"
    echo "3. Set up infrastructure Traefik for external access"
    echo "4. Deploy your first applications"
    echo "5. Configure monitoring and backup systems"
    echo ""
    echo "Initial Credentials:"
    echo "- SSH Username: ubuntu"
    echo "- SSH Key: ~/.ssh/id_rsa (from Proxmox host)"
    echo "- Dokploy: Set up during first web interface access"
    echo ""
    echo "Storage Configuration (Manual Step):"
    echo "After QNAP setup, add these lines to /etc/fstab on each VM:"
    echo "  Dev: $QNAP_HOST_IP:/share/dokploy/dev /mnt/shared-storage nfs4 defaults 0 0"
    echo "  Staging: $QNAP_HOST_IP:/share/dokploy/staging /mnt/shared-storage nfs4 defaults 0 0"
    echo "  Prod: $QNAP_HOST_IP:/share/dokploy/prod /mnt/shared-storage nfs4 defaults 0 0"
    echo ""
}

# Main deployment function
main() {
    echo "=================================================================="
    echo "  Dokploy Multi-Environment Setup"
    echo "=================================================================="
    echo ""
    
    # Load configuration
    load_config
    
    # Check prerequisites
    check_prerequisites
    
    log_info "Deploying Dokploy instances..."
    log_info "Network Mode: $NETWORK_MODE"
    log_info "Development IP: $DOKPLOY_DEV_IP"
    log_info "Staging IP: $DOKPLOY_STAGING_IP"
    log_info "Production IP: $DOKPLOY_PROD_IP"
    echo ""
    
    # Deploy each environment
    deploy_environment "dev" 200 "${DEV_MEMORY_LIMIT:-8}" "${DEV_CPU_LIMIT:-4}" 50 "$DOKPLOY_DEV_IP" "$DEV_BRIDGE" "$DEV_GATEWAY"
    echo ""
    
    deploy_environment "staging" 201 "${STAGING_MEMORY_LIMIT:-12}" "${STAGING_CPU_LIMIT:-6}" 75 "$DOKPLOY_STAGING_IP" "$STAGING_BRIDGE" "$STAGING_GATEWAY"
    echo ""
    
    deploy_environment "prod" 202 "${PROD_MEMORY_LIMIT:-16}" "${PROD_CPU_LIMIT:-8}" 100 "$DOKPLOY_PROD_IP" "$PROD_BRIDGE" "$PROD_GATEWAY"
    echo ""
    
    log_success "All Dokploy environments deployed successfully!"
    echo ""
    
    generate_summary
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
