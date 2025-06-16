#!/bin/bash
# Backup Automation Setup Script for Enterprise Homelab
# Configures comprehensive backup strategies for all infrastructure components

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
        QNAP_HOST_IP="${VLAN_QNAP_IP}"
        MONITORING_IP="${VLAN_MONITORING_IP}"
    else
        QNAP_HOST_IP="${QNAP_IP}"
        MONITORING_IP="${MONITORING_IP}"
    fi
}

# Create backup directories
create_backup_directories() {
    log_progress "Creating backup directory structure..."
    
    # Create local backup directories
    mkdir -p /var/log/homelab
    mkdir -p /opt/homelab/backups/{scripts,configs,logs}
    mkdir -p /tmp/backup-staging
    
    # Create backup mount point for QNAP
    mkdir -p /mnt/qnap-backup
    
    log_success "Backup directories created"
}

# Configure QNAP backup storage
configure_qnap_backup() {
    log_progress "Configuring QNAP backup storage..."
    
    # Test QNAP connectivity
    if ! ping -c 3 "$QNAP_HOST_IP" &> /dev/null; then
        log_warning "QNAP storage not accessible at $QNAP_HOST_IP"
        log_info "QNAP backup configuration will be skipped"
        return 0
    fi
    
    # Add QNAP backup mount to fstab
    if ! grep -q "qnap-backup" /etc/fstab; then
        echo "# QNAP backup storage" >> /etc/fstab
        echo "$QNAP_HOST_IP:/share/proxmox/backup /mnt/qnap-backup nfs4 defaults,_netdev 0 0" >> /etc/fstab
    fi
    
    # Mount QNAP backup storage
    if ! mount | grep -q "/mnt/qnap-backup"; then
        mount /mnt/qnap-backup || {
            log_warning "Failed to mount QNAP backup storage"
            log_info "Configure QNAP NFS exports first"
            return 0
        }
    fi
    
    # Create backup directory structure on QNAP
    mkdir -p /mnt/qnap-backup/{proxmox,configs,dokploy,monitoring}
    mkdir -p /mnt/qnap-backup/proxmox/{vm-backups,container-backups,system-configs}
    mkdir -p /mnt/qnap-backup/dokploy/{dev,staging,prod}
    
    log_success "QNAP backup storage configured"
}

# Create Proxmox backup script
create_proxmox_backup_script() {
    log_progress "Creating Proxmox backup script..."
    
    cat > /opt/homelab/backups/scripts/proxmox-backup.sh << 'EOF'
#!/bin/bash
# Proxmox Infrastructure Backup Script

set -euo pipefail

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="/mnt/qnap-backup/proxmox"
LOCAL_BACKUP_DIR="/tmp/backup-staging"
LOG_FILE="/var/log/homelab/proxmox-backup-${BACKUP_DATE}.log"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Create backup directory
mkdir -p "$BACKUP_DIR/system-configs/$BACKUP_DATE"
mkdir -p "$LOCAL_BACKUP_DIR"

log_info "Starting Proxmox backup process..."

# Backup Proxmox configuration
log_info "Backing up Proxmox configuration..."
tar -czf "$BACKUP_DIR/system-configs/$BACKUP_DATE/pve-config.tar.gz" \
    /etc/pve/ \
    /etc/network/interfaces* \
    /etc/hosts \
    /etc/hostname \
    /etc/crontab \
    /etc/systemd/system/*.service 2>/dev/null || log_warning "Some config files may be missing"

# Backup LXC containers
log_info "Backing up LXC containers..."
for container in $(pct list | awk 'NR>1 {print $1}'); do
    container_name=$(pct config $container | grep hostname | cut -d' ' -f2)
    log_info "Backing up container $container ($container_name)..."
    
    vzdump $container \
        --storage local \
        --compress gzip \
        --mode snapshot \
        --quiet 1 \
        --tmpdir "$LOCAL_BACKUP_DIR" || log_error "Failed to backup container $container"
    
    # Move backup to QNAP
    if ls /var/lib/vz/dump/vzdump-lxc-${container}-*.tar.gz 1> /dev/null 2>&1; then
        mv /var/lib/vz/dump/vzdump-lxc-${container}-*.tar.gz "$BACKUP_DIR/container-backups/"
        log_success "Container $container backup completed"
    fi
done

# Backup critical VMs (excluding Dokploy VMs which have their own backup)
log_info "Backing up critical VMs..."
for vm in $(qm list | awk 'NR>1 && $3!~/dokploy/ {print $1}'); do
    vm_name=$(qm config $vm | grep name | cut -d' ' -f2)
    log_info "Backing up VM $vm ($vm_name)..."
    
    vzdump $vm \
        --storage local \
        --compress gzip \
        --mode snapshot \
        --quiet 1 \
        --tmpdir "$LOCAL_BACKUP_DIR" || log_error "Failed to backup VM $vm"
    
    # Move backup to QNAP
    if ls /var/lib/vz/dump/vzdump-qemu-${vm}-*.vma.gz 1> /dev/null 2>&1; then
        mv /var/lib/vz/dump/vzdump-qemu-${vm}-*.vma.gz "$BACKUP_DIR/vm-backups/"
        log_success "VM $vm backup completed"
    fi
done

# Backup system logs
log_info "Backing up system logs..."
tar -czf "$BACKUP_DIR/system-configs/$BACKUP_DATE/system-logs.tar.gz" \
    /var/log/ 2>/dev/null || log_warning "Some log files may be inaccessible"

# Create backup manifest
log_info "Creating backup manifest..."
cat > "$BACKUP_DIR/system-configs/$BACKUP_DATE/backup-manifest.txt" << MANIFEST_EOF
Proxmox Backup Manifest
Generated: $(date)
Backup Date: $BACKUP_DATE

Contents:
- Proxmox configuration files
- LXC container backups
- Critical VM backups
- System logs
- Network configuration

LXC Containers:
$(pct list | awk 'NR>1 {print "  - " $1 " (" $3 ")"}')

Virtual Machines:
$(qm list | awk 'NR>1 {print "  - " $1 " (" $3 ")"}')

Disk Usage:
$(df -h /mnt/qnap-backup)
MANIFEST_EOF

# Cleanup old backups
log_info "Cleaning up old backups (retention: $RETENTION_DAYS days)..."
find "$BACKUP_DIR/system-configs" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
find "$BACKUP_DIR/container-backups" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
find "$BACKUP_DIR/vm-backups" -name "*.vma.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true

# Cleanup local staging
rm -rf "$LOCAL_BACKUP_DIR"/*

# Send notification
if command -v mail &> /dev/null && [[ -n "${ADMIN_EMAIL:-}" ]]; then
    echo "Proxmox backup completed successfully at $(date)" | \
        mail -s "Proxmox Backup Success - $BACKUP_DATE" "$ADMIN_EMAIL"
fi

log_success "Proxmox backup process completed successfully"
EOF
    
    chmod +x /opt/homelab/backups/scripts/proxmox-backup.sh
    log_success "Proxmox backup script created"
}

# Create Dokploy backup script
create_dokploy_backup_script() {
    log_progress "Creating Dokploy backup script..."
    
    cat > /opt/homelab/backups/scripts/dokploy-backup.sh << 'EOF'
#!/bin/bash
# Dokploy Applications Backup Script

set -euo pipefail

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="/mnt/qnap-backup/dokploy"
LOG_FILE="/var/log/homelab/dokploy-backup-${BACKUP_DATE}.log"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# Dokploy instances
DOKPLOY_INSTANCES=(
    "dev:${DOKPLOY_DEV_IP:-192.168.1.30}"
    "staging:${DOKPLOY_STAGING_IP:-192.168.1.40}"
    "prod:${DOKPLOY_PROD_IP:-192.168.1.50}"
)

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_info "Starting Dokploy applications backup..."

# Backup each Dokploy instance
for instance_info in "${DOKPLOY_INSTANCES[@]}"; do
    env="${instance_info%:*}"
    ip="${instance_info#*:}"
    
    log_info "Backing up Dokploy $env environment ($ip)..."
    
    # Check if instance is accessible
    if ! ping -c 1 "$ip" &> /dev/null; then
        log_warning "Dokploy $env instance not accessible at $ip"
        continue
    fi
    
    # Create backup directory for this environment
    mkdir -p "$BACKUP_DIR/$env/$BACKUP_DATE"
    
    # Backup Docker volumes
    log_info "Backing up Docker volumes for $env..."
    ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
        "sudo tar -czf /tmp/docker-volumes-$env-$BACKUP_DATE.tar.gz -C /var/lib/docker/volumes . 2>/dev/null || true"
    
    # Copy volume backup
    scp -o StrictHostKeyChecking=no ubuntu@"$ip":/tmp/docker-volumes-$env-$BACKUP_DATE.tar.gz \
        "$BACKUP_DIR/$env/$BACKUP_DATE/" || log_warning "Failed to copy volume backup for $env"
    
    # Backup Dokploy configuration
    log_info "Backing up Dokploy configuration for $env..."
    ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
        "sudo tar -czf /tmp/dokploy-config-$env-$BACKUP_DATE.tar.gz -C /opt/dokploy . 2>/dev/null || true"
    
    # Copy config backup
    scp -o StrictHostKeyChecking=no ubuntu@"$ip":/tmp/dokploy-config-$env-$BACKUP_DATE.tar.gz \
        "$BACKUP_DIR/$env/$BACKUP_DATE/" || log_warning "Failed to copy config backup for $env"
    
    # Backup application data from shared storage
    if ssh -o StrictHostKeyChecking=no ubuntu@"$ip" "test -d /mnt/shared-storage"; then
        log_info "Backing up shared storage data for $env..."
        ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
            "sudo tar -czf /tmp/shared-storage-$env-$BACKUP_DATE.tar.gz -C /mnt/shared-storage . 2>/dev/null || true"
        
        scp -o StrictHostKeyChecking=no ubuntu@"$ip":/tmp/shared-storage-$env-$BACKUP_DATE.tar.gz \
            "$BACKUP_DIR/$env/$BACKUP_DATE/" || log_warning "Failed to copy shared storage backup for $env"
    fi
    
    # Get application list and configurations
    log_info "Exporting application configurations for $env..."
    ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
        "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' > /tmp/containers-$env-$BACKUP_DATE.txt"
    
    scp -o StrictHostKeyChecking=no ubuntu@"$ip":/tmp/containers-$env-$BACKUP_DATE.txt \
        "$BACKUP_DIR/$env/$BACKUP_DATE/" || log_warning "Failed to copy container list for $env"
    
    # Clean up temporary files on remote host
    ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
        "rm -f /tmp/*-$env-$BACKUP_DATE.* 2>/dev/null || true"
    
    # Create backup manifest
    cat > "$BACKUP_DIR/$env/$BACKUP_DATE/backup-manifest.txt" << MANIFEST_EOF
Dokploy $env Environment Backup
Generated: $(date)
Host: $ip
Backup Date: $BACKUP_DATE

Contents:
- Docker volumes backup
- Dokploy configuration
- Shared storage data
- Container inventory

Backup Files:
$(ls -la "$BACKUP_DIR/$env/$BACKUP_DATE/")
MANIFEST_EOF
    
    log_success "Backup completed for Dokploy $env environment"
done

# Cleanup old backups
log_info "Cleaning up old Dokploy backups (retention: $RETENTION_DAYS days)..."
for env in dev staging prod; do
    find "$BACKUP_DIR/$env" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
done

# Send notification
if command -v mail &> /dev/null && [[ -n "${ADMIN_EMAIL:-}" ]]; then
    echo "Dokploy applications backup completed successfully at $(date)" | \
        mail -s "Dokploy Backup Success - $BACKUP_DATE" "$ADMIN_EMAIL"
fi

log_success "Dokploy backup process completed"
EOF
    
    chmod +x /opt/homelab/backups/scripts/dokploy-backup.sh
    log_success "Dokploy backup script created"
}

# Create configuration backup script
create_config_backup_script() {
    log_progress "Creating configuration backup script..."
    
    cat > /opt/homelab/backups/scripts/config-backup.sh << 'EOF'
#!/bin/bash
# Configuration Files Backup Script

set -euo pipefail

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="/mnt/qnap-backup/configs"
LOG_FILE="/var/log/homelab/config-backup-${BACKUP_DATE}.log"
RETENTION_DAYS="${CONFIG_BACKUP_RETENTION_DAYS:-90}"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_info "Starting configuration backup..."

# Create backup directory
mkdir -p "$BACKUP_DIR/$BACKUP_DATE"

# Backup homelab repository
log_info "Backing up homelab configuration repository..."
if [[ -d "/opt/enterprise-homelab-infrastructure" ]]; then
    tar -czf "$BACKUP_DIR/$BACKUP_DATE/homelab-repo.tar.gz" \
        -C /opt enterprise-homelab-infrastructure
    log_success "Homelab repository backed up"
else
    log_warning "Homelab repository not found"
fi

# Backup scripts and configurations
log_info "Backing up homelab scripts and configurations..."
tar -czf "$BACKUP_DIR/$BACKUP_DATE/homelab-configs.tar.gz" \
    /opt/homelab/ \
    /etc/network/interfaces* \
    /etc/hosts \
    /etc/hostname \
    /etc/systemd/system/*.service \
    /etc/crontab \
    /var/spool/cron/crontabs/ 2>/dev/null || log_warning "Some config files may be missing"

# Backup SSH keys
log_info "Backing up SSH keys..."
tar -czf "$BACKUP_DIR/$BACKUP_DATE/ssh-keys.tar.gz" \
    /root/.ssh/ \
    /home/*/.ssh/ 2>/dev/null || log_warning "Some SSH directories may not exist"

# Backup monitoring configurations (if accessible)
if [[ -n "${MONITORING_IP:-}" ]] && ping -c 1 "${MONITORING_IP}" &> /dev/null; then
    log_info "Backing up monitoring configurations..."
    ssh -o StrictHostKeyChecking=no root@"${MONITORING_IP}" \
        "tar -czf /tmp/monitoring-configs-$BACKUP_DATE.tar.gz -C /opt/monitoring . 2>/dev/null || true"
    
    scp -o StrictHostKeyChecking=no root@"${MONITORING_IP}":/tmp/monitoring-configs-$BACKUP_DATE.tar.gz \
        "$BACKUP_DIR/$BACKUP_DATE/" || log_warning "Failed to copy monitoring configs"
    
    ssh -o StrictHostKeyChecking=no root@"${MONITORING_IP}" \
        "rm -f /tmp/monitoring-configs-$BACKUP_DATE.tar.gz"
fi

# Backup AdGuard configurations
log_info "Backing up AdGuard configurations..."
for container_id in 100 101; do
    if pct status $container_id &> /dev/null; then
        container_name=$(pct config $container_id | grep hostname | cut -d' ' -f2)
        pct exec $container_id -- tar -czf /tmp/adguard-$container_name-$BACKUP_DATE.tar.gz \
            -C /etc/AdGuardHome . 2>/dev/null || true
        
        if pct exec $container_id -- test -f /tmp/adguard-$container_name-$BACKUP_DATE.tar.gz; then
            pct pull $container_id /tmp/adguard-$container_name-$BACKUP_DATE.tar.gz \
                "$BACKUP_DIR/$BACKUP_DATE/"
            pct exec $container_id -- rm -f /tmp/adguard-$container_name-$BACKUP_DATE.tar.gz
            log_success "AdGuard $container_name configuration backed up"
        fi
    fi
done

# Create backup manifest
cat > "$BACKUP_DIR/$BACKUP_DATE/backup-manifest.txt" << MANIFEST_EOF
Configuration Backup Manifest
Generated: $(date)
Backup Date: $BACKUP_DATE

Contents:
- Homelab repository
- System configurations
- SSH keys
- Monitoring configurations
- AdGuard configurations

System Information:
$(uname -a)
$(pveversion)

Backup Files:
$(ls -la "$BACKUP_DIR/$BACKUP_DATE/")
MANIFEST_EOF

# Cleanup old configuration backups
log_info "Cleaning up old configuration backups (retention: $RETENTION_DAYS days)..."
find "$BACKUP_DIR" -type d -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true

log_success "Configuration backup completed"
EOF
    
    chmod +x /opt/homelab/backups/scripts/config-backup.sh
    log_success "Configuration backup script created"
}

# Create monitoring backup script
create_monitoring_backup_script() {
    log_progress "Creating monitoring backup script..."
    
    cat > /opt/homelab/backups/scripts/monitoring-backup.sh << 'EOF'
#!/bin/bash
# Monitoring Data Backup Script

set -euo pipefail

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="/mnt/qnap-backup/monitoring"
LOG_FILE="/var/log/homelab/monitoring-backup-${BACKUP_DATE}.log"
MONITORING_IP="${MONITORING_IP:-192.168.1.26}"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_info "Starting monitoring backup..."

# Check if monitoring server is accessible
if ! ping -c 1 "$MONITORING_IP" &> /dev/null; then
    log_error "Monitoring server not accessible at $MONITORING_IP"
    exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR/$BACKUP_DATE"

# Backup Grafana data
log_info "Backing up Grafana data..."
ssh -o StrictHostKeyChecking=no root@"$MONITORING_IP" \
    "docker exec grafana grafana-cli admin export-csv > /tmp/grafana-export-$BACKUP_DATE.csv 2>/dev/null || true"

# Backup Prometheus data (configuration only, not time series data)
log_info "Backing up Prometheus configuration..."
ssh -o StrictHostKeyChecking=no root@"$MONITORING_IP" \
    "tar -czf /tmp/prometheus-config-$BACKUP_DATE.tar.gz -C /opt/monitoring/prometheus . 2>/dev/null || true"

# Backup AlertManager configuration
log_info "Backing up AlertManager configuration..."
ssh -o StrictHostKeyChecking=no root@"$MONITORING_IP" \
    "tar -czf /tmp/alertmanager-config-$BACKUP_DATE.tar.gz -C /opt/monitoring/alertmanager . 2>/dev/null || true"

# Backup Docker Compose configuration
log_info "Backing up monitoring stack configuration..."
ssh -o StrictHostKeyChecking=no root@"$MONITORING_IP" \
    "tar -czf /tmp/monitoring-stack-$BACKUP_DATE.tar.gz -C /opt/monitoring . --exclude='*/data' 2>/dev/null || true"

# Copy all backup files
for file in grafana-export prometheus-config alertmanager-config monitoring-stack; do
    scp -o StrictHostKeyChecking=no root@"$MONITORING_IP":/tmp/${file}-${BACKUP_DATE}.* \
        "$BACKUP_DIR/$BACKUP_DATE/" 2>/dev/null || log_warning "Failed to copy $file backup"
done

# Clean up temporary files on monitoring server
ssh -o StrictHostKeyChecking=no root@"$MONITORING_IP" \
    "rm -f /tmp/*-$BACKUP_DATE.* 2>/dev/null || true"

# Create backup manifest
cat > "$BACKUP_DIR/$BACKUP_DATE/backup-manifest.txt" << MANIFEST_EOF
Monitoring Backup Manifest
Generated: $(date)
Backup Date: $BACKUP_DATE
Monitoring Server: $MONITORING_IP

Contents:
- Grafana configuration export
- Prometheus configuration
- AlertManager configuration
- Docker Compose stack configuration

Note: Time series data is not backed up due to size.
Use Prometheus federation or remote storage for long-term retention.

Backup Files:
$(ls -la "$BACKUP_DIR/$BACKUP_DATE/")
MANIFEST_EOF

log_success "Monitoring backup completed"
EOF
    
    chmod +x /opt/homelab/backups/scripts/monitoring-backup.sh
    log_success "Monitoring backup script created"
}

# Create master backup orchestrator
create_master_backup_script() {
    log_progress "Creating master backup orchestrator..."
    
    cat > /opt/homelab/backups/scripts/run-all-backups.sh << 'EOF'
#!/bin/bash
# Master Backup Orchestrator Script

set -euo pipefail

# Configuration
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
LOG_FILE="/var/log/homelab/master-backup-${BACKUP_DATE}.log"
SCRIPTS_DIR="/opt/homelab/backups/scripts"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Backup scripts to run
BACKUP_SCRIPTS=(
    "config-backup.sh:Configuration Backup"
    "proxmox-backup.sh:Proxmox Infrastructure Backup"
    "dokploy-backup.sh:Dokploy Applications Backup"
    "monitoring-backup.sh:Monitoring Stack Backup"
)

log_info "Starting master backup process..."

# Check if QNAP backup storage is mounted
if ! mount | grep -q "/mnt/qnap-backup"; then
    log_error "QNAP backup storage not mounted"
    exit 1
fi

# Run each backup script
for script_info in "${BACKUP_SCRIPTS[@]}"; do
    script="${script_info%:*}"
    description="${script_info#*:}"
    
    log_info "Running $description ($script)..."
    
    if [[ -x "$SCRIPTS_DIR/$script" ]]; then
        if timeout 3600 "$SCRIPTS_DIR/$script" >> "$LOG_FILE" 2>&1; then
            log_success "$description completed successfully"
        else
            log_error "$description failed or timed out"
        fi
    else
        log_warning "$script not found or not executable"
    fi
done

# Generate backup summary
log_info "Generating backup summary..."
BACKUP_SIZE=$(du -sh /mnt/qnap-backup 2>/dev/null | cut -f1 || echo "Unknown")
DISK_USAGE=$(df -h /mnt/qnap-backup 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}' || echo "Unknown")

cat > "/var/log/homelab/backup-summary-${BACKUP_DATE}.txt" << SUMMARY_EOF
Homelab Backup Summary
Date: $(date)
Backup Session: $BACKUP_DATE

Backup Status:
$(grep -E "\[(SUCCESS|ERROR|WARNING)\]" "$LOG_FILE" | tail -20)

Storage Usage:
- Total backup size: $BACKUP_SIZE
- Disk usage: $DISK_USAGE

Next scheduled backup: $(date -d "+1 day" '+%Y-%m-%d %H:%M')
SUMMARY_EOF

# Send email notification if configured
if command -v mail &> /dev/null && [[ -n "${ADMIN_EMAIL:-}" ]]; then
    mail -s "Homelab Backup Summary - $BACKUP_DATE" "$ADMIN_EMAIL" < "/var/log/homelab/backup-summary-${BACKUP_DATE}.txt"
fi

log_success "Master backup process completed"
EOF
    
    chmod +x /opt/homelab/backups/scripts/run-all-backups.sh
    log_success "Master backup orchestrator created"
}

# Configure backup scheduling
configure_backup_scheduling() {
    log_progress "Configuring backup scheduling..."
    
    # Create cron jobs for different backup types
    cat > /etc/cron.d/homelab-backups << 'EOF'
# Homelab Infrastructure Backup Schedule
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily configuration backup (every day at 1 AM)
0 1 * * * root /opt/homelab/backups/scripts/config-backup.sh

# Weekly full infrastructure backup (Sunday at 2 AM)
0 2 * * 0 root /opt/homelab/backups/scripts/run-all-backups.sh

# Daily Dokploy application backup (every day at 3 AM)
0 3 * * * root /opt/homelab/backups/scripts/dokploy-backup.sh

# Weekly monitoring backup (Saturday at 4 AM)
0 4 * * 6 root /opt/homelab/backups/scripts/monitoring-backup.sh

# Monthly Proxmox backup (first day of month at 5 AM)
0 5 1 * * root /opt/homelab/backups/scripts/proxmox-backup.sh
EOF
    
    # Set proper permissions
    chmod 644 /etc/cron.d/homelab-backups
    
    # Restart cron service
    systemctl restart cron
    
    log_success "Backup scheduling configured"
}

# Configure log rotation for backup logs
configure_log_rotation() {
    log_progress "Configuring log rotation for backup logs..."
    
    cat > /etc/logrotate.d/homelab-backups << 'EOF'
/var/log/homelab/*.log {
    daily
    missingok
    rotate 30
    compress
    notifempty
    create 644 root root
    postrotate
        # Clean up old backup summary files
        find /var/log/homelab -name "backup-summary-*.txt" -mtime +30 -delete
    endscript
}
EOF
    
    log_success "Log rotation configured"
}

# Create backup validation script
create_backup_validation_script() {
    log_progress "Creating backup validation script..."
    
    cat > /opt/homelab/backups/scripts/validate-backups.sh << 'EOF'
#!/bin/bash
# Backup Validation Script

set -euo pipefail

BACKUP_DIR="/mnt/qnap-backup"
LOG_FILE="/var/log/homelab/backup-validation-$(date +%Y-%m-%d).log"

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log_info "Starting backup validation..."

# Check if backup storage is accessible
if ! mount | grep -q "/mnt/qnap-backup"; then
    log_error "Backup storage not mounted"
    exit 1
fi

# Validate recent backups exist
log_info "Validating recent backups..."

# Check for recent Proxmox backups
if find "$BACKUP_DIR/proxmox" -name "*.tar.gz" -mtime -7 | grep -q .; then
    log_success "Recent Proxmox backups found"
else
    log_warning "No recent Proxmox backups found"
fi

# Check for recent Dokploy backups
for env in dev staging prod; do
    if find "$BACKUP_DIR/dokploy/$env" -type f -mtime -1 | grep -q .; then
        log_success "Recent Dokploy $env backups found"
    else
        log_warning "No recent Dokploy $env backups found"
    fi
done

# Check for recent configuration backups
if find "$BACKUP_DIR/configs" -type f -mtime -1 | grep -q .; then
    log_success "Recent configuration backups found"
else
    log_warning "No recent configuration backups found"
fi

# Test backup file integrity
log_info "Testing backup file integrity..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime -7 | while read -r backup_file; do
    if tar -tzf "$backup_file" &> /dev/null; then
        log_success "Backup file integrity OK: $(basename "$backup_file")"
    else
        log_error "Backup file corrupted: $backup_file"
    fi
done

# Check backup storage space
log_info "Checking backup storage space..."
USAGE=$(df "$BACKUP_DIR" | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ $USAGE -gt 90 ]]; then
    log_error "Backup storage usage critical: ${USAGE}%"
elif [[ $USAGE -gt 80 ]]; then
    log_warning "Backup storage usage high: ${USAGE}%"
else
    log_success "Backup storage usage normal: ${USAGE}%"
fi

log_success "Backup validation completed"
EOF
    
    chmod +x /opt/homelab/backups/scripts/validate-backups.sh
    log_success "Backup validation script created"
}

# Generate backup summary
generate_summary() {
    log_info "=== Backup Automation Summary ==="
    echo ""
    echo "Backup Storage: /mnt/qnap-backup (${QNAP_HOST_IP})"
    echo ""
    echo "Backup Scripts Created:"
    echo "  - Proxmox infrastructure backup"
    echo "  - Dokploy applications backup"
    echo "  - Configuration files backup"
    echo "  - Monitoring stack backup"
    echo "  - Master backup orchestrator"
    echo "  - Backup validation script"
    echo ""
    echo "Backup Schedule:"
    echo "  - Daily: Configuration backup (1 AM)"
    echo "  - Daily: Dokploy applications (3 AM)"
    echo "  - Weekly: Full infrastructure (Sunday 2 AM)"
    echo "  - Weekly: Monitoring stack (Saturday 4 AM)"
    echo "  - Monthly: Proxmox VMs/containers (1st 5 AM)"
    echo ""
    echo "Retention Policy:"
    echo "  - Infrastructure backups: ${BACKUP_RETENTION_DAYS:-30} days"
    echo "  - Configuration backups: ${CONFIG_BACKUP_RETENTION_DAYS:-90} days"
    echo "  - Log files: 30 days"
    echo ""
    echo "Manual Operations:"
    echo "  - Run all backups: /opt/homelab/backups/scripts/run-all-backups.sh"
    echo "  - Validate backups: /opt/homelab/backups/scripts/validate-backups.sh"
    echo "  - Check logs: tail -f /var/log/homelab/*backup*.log"
    echo ""
    echo "Next Steps:"
    echo "1. Configure QNAP NFS exports for backup storage"
    echo "2. Test backup scripts manually before relying on automation"
    echo "3. Set up offsite backup replication (if configured)"
    echo "4. Configure email notifications for backup status"
    echo "5. Test restore procedures regularly"
    echo ""
}

# Main backup automation setup
main() {
    echo "=================================================================="
    echo "  Backup Automation Setup for Enterprise Homelab"
    echo "=================================================================="
    echo ""
    
    # Load configuration
    load_config
    
    log_info "Setting up comprehensive backup automation..."
    log_info "QNAP Storage: $QNAP_HOST_IP"
    log_info "Backup Retention: ${BACKUP_RETENTION_DAYS:-30} days"
    echo ""
    
    # Setup backup infrastructure
    create_backup_directories
    configure_qnap_backup
    create_proxmox_backup_script
    create_dokploy_backup_script
    create_config_backup_script
    create_monitoring_backup_script
    create_master_backup_script
    create_backup_validation_script
    configure_backup_scheduling
    configure_log_rotation
    
    echo ""
    log_success "Backup automation setup completed successfully!"
    echo ""
    
    generate_summary
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
