#!/bin/bash
# Enterprise Homelab Infrastructure Installation Script
# Main installation script for Proxmox VE infrastructure automation
# Supports both single network and VLAN configurations

set -euo pipefail

# Script version and information
SCRIPT_VERSION="2.0"
SCRIPT_NAME="Enterprise Homelab Infrastructure Installer"

# Default configuration file
CONFIG_FILE="config/homelab.conf"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
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

log_debug() {
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        echo -e "${PURPLE}[DEBUG]${NC} $1"
    fi
}

# Progress tracking
show_progress() {
    local step=$1
    local total=$2
    local description=$3
    local percentage=$((step * 100 / total))
    
    echo -e "${CYAN}[PROGRESS: ${percentage}%]${NC} Step $step/$total: $description"
}

# Error handling
handle_error() {
    local line_no=$1
    local error_code=$2
    log_error "Script failed at line $line_no with exit code $error_code"
    log_error "Check the log file for details: $LOG_FILE"
    exit $error_code
}

trap 'handle_error $LINENO $?' ERR

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/tmp/homelab-install-$(date +%Y%m%d-%H%M%S).log"
BACKUP_DIR="/tmp/homelab-backup-$(date +%Y%m%d-%H%M%S)"

# Prerequisites check
check_prerequisites() {
    show_progress 1 20 "Checking prerequisites"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check if running on Proxmox
    if ! command -v pveversion &> /dev/null; then
        log_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    
    # Check Proxmox version
    local pve_version=$(pveversion | grep "pve-manager" | cut -d'/' -f2 | cut -d'-' -f1)
    local major_version=$(echo $pve_version | cut -d'.' -f1)
    
    if [[ $major_version -lt 8 ]]; then
        log_error "Proxmox VE 8.0 or higher is required (found: $pve_version)"
        exit 1
    fi
    
    log_success "Proxmox VE $pve_version detected"
    
    # Check available disk space (minimum 50GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local available_gb=$((available_space / 1024 / 1024))
    
    if [[ $available_gb -lt 50 ]]; then
        log_error "Insufficient disk space. Required: 50GB, Available: ${available_gb}GB"
        exit 1
    fi
    
    # Check available memory (minimum 8GB)
    local available_memory=$(free -g | awk 'NR==2{print $2}')
    
    if [[ $available_memory -lt 8 ]]; then
        log_error "Insufficient memory. Required: 8GB, Available: ${available_memory}GB"
        exit 1
    fi
    
    # Check required commands
    local required_commands=("curl" "wget" "git" "docker" "docker-compose")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_warning "Required command '$cmd' not found. Will install during setup."
        fi
    done
    
    log_success "Prerequisites check completed"
}

# Load configuration
load_configuration() {
    show_progress 2 20 "Loading configuration"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Please copy config/homelab.conf.example to config/homelab.conf and customize it"
        exit 1
    fi
    
    # Source configuration file
    source "$CONFIG_FILE"
    
    # Validate required configuration
    local required_vars=(
        "DOMAIN_NAME"
        "NETWORK_MODE"
        "DNS_PROVIDER"
        "ADMIN_EMAIL"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required configuration variable '$var' is not set in $CONFIG_FILE"
            exit 1
        fi
    done
    
    # Set IP variables based on network mode
    if [[ "$NETWORK_MODE" == "vlan" ]]; then
        PROXMOX_HOST_IP="${VLAN_PROXMOX_IP}"
        ADGUARD_PRIMARY="${VLAN_ADGUARD_PRIMARY_IP}"
        ADGUARD_SECONDARY="${VLAN_ADGUARD_SECONDARY_IP}"
        DOKPLOY_DEV="${VLAN_DOKPLOY_DEV_IP}"
        DOKPLOY_STAGING="${VLAN_DOKPLOY_STAGING_IP}"
        DOKPLOY_PROD="${VLAN_DOKPLOY_PROD_IP}"
        QNAP_HOST_IP="${VLAN_QNAP_IP}"
        MONITORING_HOST_IP="${VLAN_MONITORING_IP}"
    else
        PROXMOX_HOST_IP="${PROXMOX_IP}"
        ADGUARD_PRIMARY="${ADGUARD_PRIMARY_IP}"
        ADGUARD_SECONDARY="${ADGUARD_SECONDARY_IP}"
        DOKPLOY_DEV="${DOKPLOY_DEV_IP}"
        DOKPLOY_STAGING="${DOKPLOY_STAGING_IP}"
        DOKPLOY_PROD="${DOKPLOY_PROD_IP}"
        QNAP_HOST_IP="${QNAP_IP}"
        MONITORING_HOST_IP="${MONITORING_IP}"
    fi
    
    log_success "Configuration loaded successfully"
    log_info "Network Mode: $NETWORK_MODE"
    log_info "Domain: $DOMAIN_NAME"
    log_info "DNS Provider: $DNS_PROVIDER"
}

# System preparation
prepare_system() {
    show_progress 3 20 "Preparing system"
    
    # Update package lists
    log_info "Updating package lists..."
    apt update >> "$LOG_FILE" 2>&1
    
    # Install essential packages
    log_info "Installing essential packages..."
    apt install -y \
        curl \
        wget \
        vim \
        htop \
        iotop \
        iftop \
        net-tools \
        dnsutils \
        screen \
        tmux \
        git \
        jq \
        unzip \
        nfs-common \
        open-iscsi \
        multipath-tools \
        ca-certificates \
        gnupg \
        lsb-release >> "$LOG_FILE" 2>&1
    
    # Configure timezone
    if [[ -n "${TIMEZONE:-}" ]]; then
        log_info "Setting timezone to $TIMEZONE"
        timedatectl set-timezone "$TIMEZONE"
    fi
    
    # Set up hosts file
    log_info "Configuring hosts file..."
    cat >> /etc/hosts << EOF

# Enterprise Homelab Infrastructure
$PROXMOX_HOST_IP    pve-01.lab.local pve-01
$ADGUARD_PRIMARY    adguard-primary.lab.local
$ADGUARD_SECONDARY  adguard-secondary.lab.local
$MONITORING_HOST_IP monitoring.lab.local
$DOKPLOY_DEV        dokploy-dev.lab.local
$DOKPLOY_STAGING    dokploy-staging.lab.local
$DOKPLOY_PROD       dokploy-prod.lab.local
$QNAP_HOST_IP       qnap.lab.local storage.lab.local
$GATEWAY_IP         gateway.lab.local ucg-ultra.lab.local
EOF
    
    log_success "System preparation completed"
}

# Docker installation
install_docker() {
    show_progress 4 20 "Installing Docker"
    
    if command -v docker &> /dev/null; then
        log_info "Docker already installed"
        return 0
    fi
    
    # Install Docker using official script
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >> "$LOG_FILE" 2>&1
    rm get-docker.sh
    
    # Install Docker Compose
    log_info "Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    # Add current user to docker group (if not root)
    if [[ $EUID -ne 0 ]] && [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER"
    fi
    
    # Create Docker networks
    docker network create traefik-net || true
    docker network create monitoring-net || true
    
    log_success "Docker installation completed"
}

# Network configuration
configure_networking() {
    show_progress 5 20 "Configuring networking"
    
    if [[ "$NETWORK_MODE" == "vlan" ]]; then
        configure_vlan_networking
    else
        configure_single_networking
    fi
    
    log_success "Network configuration completed"
}

# Single network configuration
configure_single_networking() {
    log_info "Configuring single network setup..."
    
    # Basic network bridge configuration
    cat > /etc/network/interfaces.d/homelab << EOF
# Homelab single network configuration
# Main bridge for all VMs and containers
auto vmbr0
iface vmbr0 inet static
    address $PROXMOX_HOST_IP/24
    gateway $GATEWAY_IP
    bridge-ports ens18
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    
# Optional: Additional bridge for storage traffic
auto vmbr1
iface vmbr1 inet static
    address ${PROXMOX_HOST_IP%.*}.11/24
    bridge-ports ens19
    bridge-stp off
    bridge-fd 0
    comment "Storage network bridge"
EOF
    
    log_info "Single network configuration applied"
}

# VLAN network configuration
configure_vlan_networking() {
    log_info "Configuring VLAN network setup..."
    
    cat > /etc/network/interfaces.d/homelab-vlans << EOF
# Homelab VLAN configuration
# Requires managed switch with VLAN support

auto vmbr0
iface vmbr0 inet static
    address $PROXMOX_HOST_IP/24
    gateway ${VLAN_PROXMOX_IP%.*}.1
    bridge-ports ens18
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes

# Management VLAN (10)
auto vmbr10
iface vmbr10 inet static
    address $VLAN_PROXMOX_IP/24
    bridge-ports ens18.10
    bridge-stp off
    bridge-fd 0

# Infrastructure VLAN (20)
auto vmbr20
iface vmbr20 inet manual
    bridge-ports ens18.20
    bridge-stp off
    bridge-fd 0

# Development VLAN (30)
auto vmbr30
iface vmbr30 inet manual
    bridge-ports ens18.30
    bridge-stp off
    bridge-fd 0

# Staging VLAN (40)
auto vmbr40
iface vmbr40 inet manual
    bridge-ports ens18.40
    bridge-stp off
    bridge-fd 0

# Production VLAN (50)
auto vmbr50
iface vmbr50 inet manual
    bridge-ports ens18.50
    bridge-stp off
    bridge-fd 0

# Storage VLAN (60)
auto vmbr60
iface vmbr60 inet manual
    bridge-ports ens18.60
    bridge-stp off
    bridge-fd 0
EOF
    
    log_warning "VLAN configuration applied. A managed switch is required."
    log_warning "Configure VLANs on your switch before rebooting Proxmox."
}

# Storage configuration
configure_storage() {
    show_progress 6 20 "Configuring storage"
    
    # Wait for QNAP to be available
    log_info "Waiting for QNAP storage to be available..."
    for i in {1..30}; do
        if ping -c 1 "$QNAP_HOST_IP" &> /dev/null; then
            log_success "QNAP storage is accessible"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log_warning "QNAP storage not accessible. Will configure later."
            return 0
        fi
        sleep 10
    done
    
    # Configure QNAP NFS storage
    if [[ "${QNAP_NFS_ENABLED:-true}" == "true" ]]; then
        configure_qnap_storage
    fi
    
    log_success "Storage configuration completed"
}

# QNAP storage configuration
configure_qnap_storage() {
    log_info "Configuring QNAP NFS storage..."
    
    # Add QNAP NFS storage for VMs and containers
    pvesm add nfs qnap-vm-storage \
        --server "$QNAP_HOST_IP" \
        --export /share/proxmox/vm-storage \
        --content images,vztmpl,iso,backup \
        --options vers=4 || log_warning "VM storage already configured"

    # Add QNAP NFS storage for container templates  
    pvesm add nfs qnap-templates \
        --server "$QNAP_HOST_IP" \
        --export /share/proxmox/templates \
        --content vztmpl,iso \
        --options vers=4 || log_warning "Template storage already configured"
    
    # Add QNAP NFS for backups
    pvesm add nfs qnap-backup \
        --server "$QNAP_HOST_IP" \
        --export /share/proxmox/backup \
        --content backup \
        --options vers=4 || log_warning "Backup storage already configured"
    
    # Add QNAP NFS for shared application data
    pvesm add nfs qnap-shared \
        --server "$QNAP_HOST_IP" \
        --export /share/proxmox/shared \
        --content images,vztmpl \
        --options vers=4 || log_warning "Shared storage already configured"
    
    log_success "QNAP storage configuration completed"
}

# Container template creation
create_container_templates() {
    show_progress 7 20 "Creating container templates"
    
    # Download latest Debian template if not exists
    log_info "Downloading Debian container template..."
    if ! pveam list local | grep -q "debian-12-standard"; then
        pveam download local debian-12-standard_12.2-1_amd64.tar.zst || \
            log_warning "Failed to download Debian template"
    fi
    
    # Download Ubuntu template if not exists
    log_info "Downloading Ubuntu container template..."
    if ! pveam list local | grep -q "ubuntu-22.04-standard"; then
        pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst || \
            log_warning "Failed to download Ubuntu template"
    fi
    
    log_success "Container templates ready"
}

# Create VM template for Dokploy
create_vm_template() {
    show_progress 8 20 "Creating VM template for Dokploy"
    
    local template_id=9000
    local template_name="dokploy-template"
    
    # Check if template already exists
    if qm status $template_id &> /dev/null; then
        log_info "VM template $template_id already exists"
        return 0
    fi
    
    # Download Ubuntu Cloud Image
    log_info "Downloading Ubuntu Cloud Image..."
    cd /var/lib/vz/template/iso
    wget -O ubuntu-22.04-server-cloudimg-amd64.img \
        https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img || {
        log_error "Failed to download Ubuntu cloud image"
        return 1
    }
    
    # Create VM template
    log_info "Creating VM template..."
    qm create $template_id \
        --name $template_name \
        --memory 2048 \
        --cores 2 \
        --net0 virtio,bridge=vmbr0 \
        --bootdisk scsi0 \
        --ostype l26 \
        --agent enabled=1,fstrim_cloned_disks=1
    
    # Import the disk
    qm importdisk $template_id ubuntu-22.04-server-cloudimg-amd64.img local-lvm
    
    # Configure the VM
    qm set $template_id \
        --scsi0 local-lvm:vm-$template_id-disk-0 \
        --ide2 local-lvm:cloudinit \
        --boot c \
        --bootdisk scsi0 \
        --serial0 socket \
        --vga serial0 \
        --ipconfig0 ip=dhcp
    
    # Create SSH key if it doesn't exist
    if [[ ! -f ~/.ssh/id_rsa ]]; then
        log_info "Creating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
    fi
    
    # Configure cloud-init
    qm set $template_id \
        --ciuser ubuntu \
        --cipassword $(openssl passwd -6 "${DOKPLOY_ADMIN_PASSWORD:-ubuntu}") \
        --sshkeys ~/.ssh/id_rsa.pub \
        --ciupgrade 1
    
    # Convert to template
    qm template $template_id
    
    log_success "VM template created with ID $template_id"
}

# AdGuard Home setup
setup_adguard() {
    show_progress 9 20 "Setting up AdGuard Home"
    
    if [[ "${ENABLE_ADGUARD:-true}" != "true" ]]; then
        log_info "AdGuard setup skipped (disabled in configuration)"
        return 0
    fi
    
    # Execute AdGuard setup script
    if [[ -f "$SCRIPT_DIR/setup-adguard.sh" ]]; then
        log_info "Running AdGuard setup script..."
        bash "$SCRIPT_DIR/setup-adguard.sh"
    else
        log_warning "AdGuard setup script not found, setting up manually..."
        setup_adguard_manual
    fi
    
    log_success "AdGuard Home setup completed"
}

# Manual AdGuard setup
setup_adguard_manual() {
    # Primary AdGuard instance
    log_info "Creating primary AdGuard instance..."
    create_lxc_container 100 "adguard-primary" "$ADGUARD_PRIMARY" 1024 2 8
    
    # Install AdGuard Home on primary
    pct exec 100 -- bash -c "
        curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
        systemctl enable AdGuardHome
        systemctl start AdGuardHome
    "
    
    # Secondary AdGuard instance  
    log_info "Creating secondary AdGuard instance..."
    create_lxc_container 101 "adguard-secondary" "$ADGUARD_SECONDARY" 1024 2 8
    
    # Install AdGuard Home on secondary
    pct exec 101 -- bash -c "
        curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
        systemctl enable AdGuardHome
        systemctl start AdGuardHome
    "
}

# Infrastructure services setup
setup_infrastructure_services() {
    show_progress 10 20 "Setting up infrastructure services"
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]]; then
        setup_monitoring_stack
    fi
    
    if [[ "${ENABLE_TRAEFIK:-true}" == "true" ]]; then
        setup_traefik_infrastructure
    fi
    
    log_success "Infrastructure services setup completed"
}

# Monitoring stack setup
setup_monitoring_stack() {
    log_info "Setting up monitoring stack..."
    
    # Create monitoring container
    create_lxc_container 110 "monitoring" "$MONITORING_HOST_IP" 4096 4 20
    
    # Install Docker on monitoring container
    pct exec 110 -- bash -c "
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        systemctl enable docker
        systemctl start docker
        
        # Install Docker Compose
        curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        # Create monitoring directories
        mkdir -p /opt/monitoring/{prometheus,grafana,alertmanager}
    "
    
    # Copy monitoring configuration
    if [[ -d "$PROJECT_ROOT/monitoring" ]]; then
        log_info "Copying monitoring configuration..."
        pct push 110 "$PROJECT_ROOT/monitoring" /opt/monitoring --recursive
    fi
    
    log_success "Monitoring stack deployed"
}

# Traefik infrastructure setup
setup_traefik_infrastructure() {
    log_info "Setting up Traefik infrastructure..."
    
    # Create Traefik directories
    mkdir -p /opt/traefik/{dynamic,certs,logs}
    
    # Copy Traefik configuration
    if [[ -d "$PROJECT_ROOT/traefik" ]]; then
        cp -r "$PROJECT_ROOT/traefik"/* /opt/traefik/
    fi
    
    # Set up environment file for Traefik
    cat > /opt/traefik/.env << EOF
CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL:-}
CLOUDFLARE_DNS_API_TOKEN=${CLOUDFLARE_API_TOKEN:-}
DOMAIN_NAME=${DOMAIN_NAME}
EOF
    
    # Deploy Traefik
    cd /opt/traefik
    docker-compose up -d
    
    log_success "Traefik infrastructure deployed"
}

# Dokploy deployment
setup_dokploy_instances() {
    show_progress 11 20 "Setting up Dokploy instances"
    
    if [[ "${ENABLE_DOKPLOY:-true}" != "true" ]]; then
        log_info "Dokploy setup skipped (disabled in configuration)"
        return 0
    fi
    
    # Execute Dokploy setup script
    if [[ -f "$SCRIPT_DIR/setup-dokploy.sh" ]]; then
        log_info "Running Dokploy setup script..."
        bash "$SCRIPT_DIR/setup-dokploy.sh"
    else
        log_warning "Dokploy setup script not found, setting up manually..."
        setup_dokploy_manual
    fi
    
    log_success "Dokploy instances setup completed"
}

# Manual Dokploy setup
setup_dokploy_manual() {
    # Development Environment
    log_info "Creating Dokploy development environment..."
    local dev_vmid=200
    qm clone 9000 $dev_vmid --name dokploy-dev --full
    qm set $dev_vmid \
        --memory $((DEV_MEMORY_LIMIT * 1024)) \
        --cores $DEV_CPU_LIMIT \
        --net0 virtio,bridge=vmbr0 \
        --ipconfig0 ip=$DOKPLOY_DEV/24,gw=$GATEWAY_IP \
        --onboot 1
    qm resize $dev_vmid scsi0 +50G
    qm start $dev_vmid
    
    # Staging Environment  
    log_info "Creating Dokploy staging environment..."
    local staging_vmid=201
    qm clone 9000 $staging_vmid --name dokploy-staging --full
    qm set $staging_vmid \
        --memory $((STAGING_MEMORY_LIMIT * 1024)) \
        --cores $STAGING_CPU_LIMIT \
        --net0 virtio,bridge=vmbr0 \
        --ipconfig0 ip=$DOKPLOY_STAGING/24,gw=$GATEWAY_IP \
        --onboot 1
    qm resize $staging_vmid scsi0 +75G
    qm start $staging_vmid
    
    # Production Environment
    log_info "Creating Dokploy production environment..."
    local prod_vmid=202  
    qm clone 9000 $prod_vmid --name dokploy-prod --full
    qm set $prod_vmid \
        --memory $((PROD_MEMORY_LIMIT * 1024)) \
        --cores $PROD_CPU_LIMIT \
        --net0 virtio,bridge=vmbr0 \
        --ipconfig0 ip=$DOKPLOY_PROD/24,gw=$GATEWAY_IP \
        --onboot 1
    qm resize $prod_vmid scsi0 +100G
    qm start $prod_vmid
    
    # Wait for VMs to be ready and install Dokploy
    sleep 120
    install_dokploy_on_vm $dev_vmid "$DOKPLOY_DEV" "dev"
    install_dokploy_on_vm $staging_vmid "$DOKPLOY_STAGING" "staging"  
    install_dokploy_on_vm $prod_vmid "$DOKPLOY_PROD" "prod"
}

# Backup automation setup
setup_backup_automation() {
    show_progress 12 20 "Setting up backup automation"
    
    if [[ "${ENABLE_BACKUP:-true}" != "true" ]]; then
        log_info "Backup setup skipped (disabled in configuration)"
        return 0
    fi
    
    # Execute backup setup script
    if [[ -f "$SCRIPT_DIR/backup-automation.sh" ]]; then
        log_info "Running backup automation script..."
        bash "$SCRIPT_DIR/backup-automation.sh"
    else
        log_warning "Backup automation script not found"
    fi
    
    log_success "Backup automation setup completed"
}

# Utility functions
create_lxc_container() {
    local container_id=$1
    local container_name=$2
    local ip_address=$3
    local memory=$4
    local cores=$5
    local storage_size=$6
    
    # Check if container already exists
    if pct status $container_id &> /dev/null; then
        log_info "Container $container_id already exists"
        return 0
    fi
    
    log_info "Creating LXC container: $container_name"
    
    # Use available template
    local template_path=""
    if pveam list local | grep -q "debian-12-standard"; then
        template_path="local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    elif pveam list local | grep -q "ubuntu-22.04-standard"; then
        template_path="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
    else
        log_error "No suitable template found for container creation"
        return 1
    fi
    
    # Create container
    pct create $container_id $template_path \
        --hostname $container_name \
        --memory $memory \
        --cores $cores \
        --rootfs local-lvm:$storage_size \
        --net0 name=eth0,bridge=vmbr0,ip=$ip_address/24,gw=$GATEWAY_IP \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --protection 0 \
        --start 1
    
    # Wait for container to start
    sleep 15
    
    # Basic container setup
    pct exec $container_id -- bash -c "
        apt update && apt upgrade -y
        apt install -y curl wget vim htop net-tools dnsutils systemd-resolved
        
        # Set timezone
        ln -sf /usr/share/zoneinfo/${TIMEZONE:-UTC} /etc/localtime
        
        # Configure DNS
        echo 'nameserver $ADGUARD_PRIMARY' > /etc/resolv.conf
        echo 'nameserver $ADGUARD_SECONDARY' >> /etc/resolv.conf
        echo 'domain lab.local' >> /etc/resolv.conf
    "
    
    log_success "LXC container $container_name created successfully"
}

# Install Dokploy on VM
install_dokploy_on_vm() {
    local vmid=$1
    local ip=$2
    local env=$3
    
    log_info "Installing Dokploy on $env environment ($ip)..."
    
    # Wait for SSH to be available
    log_info "Waiting for SSH connectivity to $ip..."
    for i in {1..60}; do
        if nc -z $ip 22 2>/dev/null; then
            log_info "SSH is available on $ip"
            break
        fi
        if [[ $i -eq 60 ]]; then
            log_error "SSH timeout for $ip"
            return 1
        fi
        sleep 10
    done
    
    # Create installation script
    cat > /tmp/dokploy-install-${env}.sh << 'SCRIPT_EOF'
#!/bin/bash
set -e

# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Create mount point for shared storage
sudo mkdir -p /mnt/shared-storage

# Install Dokploy
curl -sSL https://dokploy.com/install.sh | sh

echo "Dokploy installation completed"
SCRIPT_EOF

    # Copy and execute script
    scp -o StrictHostKeyChecking=no /tmp/dokploy-install-${env}.sh ubuntu@$ip:/tmp/
    
    # Execute installation script
    ssh -o StrictHostKeyChecking=no ubuntu@$ip "chmod +x /tmp/dokploy-install-${env}.sh && /tmp/dokploy-install-${env}.sh"
    
    # Clean up
    rm /tmp/dokploy-install-${env}.sh
    
    log_success "Dokploy installation completed on $env environment"
}

# Post-installation configuration
post_installation_tasks() {
    show_progress 13 20 "Running post-installation tasks"
    
    # Create backup of configuration
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/pve "$BACKUP_DIR/"
    cp "$CONFIG_FILE" "$BACKUP_DIR/"
    
    # Set up log rotation
    setup_log_rotation
    
    # Configure automatic updates (if enabled)
    if [[ "${AUTO_UPDATES:-false}" == "true" ]]; then
        setup_automatic_updates
    fi
    
    log_success "Post-installation tasks completed"
}

# Log rotation setup
setup_log_rotation() {
    log_info "Setting up log rotation..."
    
    cat > /etc/logrotate.d/homelab << EOF
/var/log/homelab/*.log {
    daily
    missingok
    rotate 30
    compress
    notifempty
    create 644 root root
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
    
    # Create log directory
    mkdir -p /var/log/homelab
}

# Automatic updates setup
setup_automatic_updates() {
    log_info "Setting up automatic updates..."
    
    apt install -y unattended-upgrades
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << EOF
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "Proxmox:*";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    systemctl enable unattended-upgrades
}

# System validation
validate_installation() {
    show_progress 14 20 "Validating installation"
    
    local validation_errors=0
    
    # Check essential services
    log_info "Checking essential services..."
    
    # Check Docker
    if ! systemctl is-active --quiet docker; then
        log_error "Docker service is not running"
        ((validation_errors++))
    fi
    
    # Check AdGuard instances
    if [[ "${ENABLE_ADGUARD:-true}" == "true" ]]; then
        for id in 100 101; do
            if ! pct status $id | grep -q "running"; then
                log_error "AdGuard container $id is not running"
                ((validation_errors++))
            fi
        done
    fi
    
    # Check network connectivity
    log_info "Testing network connectivity..."
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        log_error "No internet connectivity"
        ((validation_errors++))
    fi
    
    # Check DNS resolution
    if ! nslookup google.com "$ADGUARD_PRIMARY" &> /dev/null; then
        log_error "DNS resolution failed"
        ((validation_errors++))
    fi
    
    # Check storage
    if [[ "${QNAP_NFS_ENABLED:-true}" == "true" ]]; then
        if ! showmount -e "$QNAP_HOST_IP" &> /dev/null; then
            log_error "QNAP NFS not accessible"
            ((validation_errors++))
        fi
    fi
    
    if [[ $validation_errors -eq 0 ]]; then
        log_success "All validation checks passed"
    else
        log_error "$validation_errors validation errors found"
        return 1
    fi
}

# Generate configuration summary
generate_summary() {
    show_progress 15 20 "Generating configuration summary"
    
    local summary_file="/tmp/homelab-summary-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > "$summary_file" << EOF
=================================================================
Enterprise Homelab Infrastructure Installation Summary
=================================================================
Installation Date: $(date)
Configuration File: $CONFIG_FILE
Log File: $LOG_FILE

Network Configuration:
- Mode: $NETWORK_MODE
- Domain: $DOMAIN_NAME
- Proxmox IP: $PROXMOX_HOST_IP
- Gateway: $GATEWAY_IP

Services Deployed:
- AdGuard Primary: $ADGUARD_PRIMARY:3000
- AdGuard Secondary: $ADGUARD_SECONDARY:3000
- Monitoring: $MONITORING_HOST_IP:3000
- QNAP Storage: $QNAP_HOST_IP:443

Dokploy Instances:
- Development: $DOKPLOY_DEV:3000
- Staging: $DOKPLOY_STAGING:3000
- Production: $DOKPLOY_PROD:3000

Access Information:
- Proxmox Web UI: https://$PROXMOX_HOST_IP:8006
- AdGuard Primary: http://$ADGUARD_PRIMARY:3000
- Monitoring (Grafana): http://$MONITORING_HOST_IP:3000

Next Steps:
1. Configure UCG Ultra using: config/ucg-ultra-config.sh
2. Set up external DNS records: config/dns-records.txt
3. Configure SSL certificates for external access
4. Deploy applications via Dokploy web interfaces
5. Configure monitoring dashboards and alerts

For troubleshooting and operational procedures, see:
- docs/troubleshooting.md
- docs/operational-runbooks.md
- docs/implementation-guide.md

=================================================================
EOF
    
    # Display summary
    cat "$summary_file"
    
    # Copy summary to accessible location
    cp "$summary_file" /var/log/homelab/installation-summary.txt
    
    log_success "Installation summary saved to: $summary_file"
}

# Main installation function
main() {
    echo "=================================================================="
    echo "  $SCRIPT_NAME v$SCRIPT_VERSION"
    echo "=================================================================="
    echo ""
    echo "This script will install and configure a complete enterprise"
    echo "homelab infrastructure including:"
    echo ""
    echo "- Proxmox VE infrastructure automation"
    echo "- AdGuard Home DNS servers (HA pair)"
    echo "- Dokploy container orchestration (dev/staging/prod)"
    echo "- Comprehensive monitoring stack"
    echo "- Automated backup systems"
    echo "- Network configuration and security"
    echo ""
    
    # Confirm before proceeding
    if [[ "${FORCE_INSTALL:-false}" != "true" ]]; then
        read -p "Continue with installation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled by user"
            exit 0
        fi
    fi
    
    # Start logging
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    log_info "Starting installation at $(date)"
    log_info "Log file: $LOG_FILE"
    
    # Run installation steps
    check_prerequisites
    load_configuration
    prepare_system
    install_docker
    configure_networking
    configure_storage
    create_container_templates
    create_vm_template
    setup_adguard
    setup_infrastructure_services
    setup_dokploy_instances
    setup_backup_automation
    post_installation_tasks
    validate_installation
    generate_summary
    
    echo ""
    log_success "=== Installation Completed Successfully! ==="
    echo ""
    log_info "Installation log: $LOG_FILE"
    log_info "Configuration summary: /var/log/homelab/installation-summary.txt"
    echo ""
    log_warning "IMPORTANT: Review the next steps in the summary above"
    log_warning "Configure UCG Ultra and external DNS before deploying applications"
    echo ""
    
    if [[ "$NETWORK_MODE" == "vlan" ]]; then
        log_warning "REBOOT REQUIRED: Network changes need system restart"
        log_warning "Run 'reboot' after reviewing the configuration"
    fi
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
