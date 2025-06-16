#!/bin/bash
# Backup Setup and Configuration Script
# Sets up automated backup system for homelab infrastructure

set -euo pipefail

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration variables
BACKUP_USER="backup"
BACKUP_HOME="/home/backup"
BACKUP_SCRIPT_DIR="/opt/backup"
BACKUP_LOG_DIR="/var/log/backup"
QNAP_MOUNT_POINT="/mnt/qnap-backup"

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Create backup user
create_backup_user() {
    log_info "Creating backup user..."
    
    if ! id "$BACKUP_USER" &>/dev/null; then
        useradd -r -m -d "$BACKUP_HOME" -s /bin/bash "$BACKUP_USER"
        log_success "Backup user created: $BACKUP_USER"
    else
        log_warning "Backup user already exists: $BACKUP_USER"
    fi
    
    # Create SSH key for backup user
    if [[ ! -f "$BACKUP_HOME/.ssh/id_rsa" ]]; then
        sudo -u "$BACKUP_USER" mkdir -p "$BACKUP_HOME/.ssh"
        sudo -u "$BACKUP_USER" ssh-keygen -t rsa -b 4096 -f "$BACKUP_HOME/.ssh/id_rsa" -N ""
        chmod 700 "$BACKUP_HOME/.ssh"
        chmod 600 "$BACKUP_HOME/.ssh/id_rsa"
        chmod 644 "$BACKUP_HOME/.ssh/id_rsa.pub"
        log_success "SSH key generated for backup user"
        
        log_info "Public key for distribution to Dokploy instances:"
        cat "$BACKUP_HOME/.ssh/id_rsa.pub"
    fi
}

# Setup directories and permissions
setup_directories() {
    log_info "Setting up backup directories..."
    
    # Create backup script directory
    mkdir -p "$BACKUP_SCRIPT_DIR"
    chmod 755 "$BACKUP_SCRIPT_DIR"
    
    # Create log directory
    mkdir -p "$BACKUP_LOG_DIR"
    chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_LOG_DIR"
    chmod 755 "$BACKUP_LOG_DIR"
    
    # Create QNAP mount point
    mkdir -p "$QNAP_MOUNT_POINT"
    chown "$BACKUP_USER:$BACKUP_USER" "$QNAP_MOUNT_POINT"
    chmod 755 "$QNAP_MOUNT_POINT"
    
    # Create backup subdirectories
    sudo -u "$BACKUP_USER" mkdir -p "$QNAP_MOUNT_POINT"/{daily,weekly,monthly}
    
    log_success "Backup directories created"
}

# Install required packages
install_packages() {
    log_info "Installing required packages..."
    
    apt update
    apt install -y \
        rsync \
        borgbackup \
        rclone \
        awscli \
        nfs-common \
        mail-utils \
        curl \
        jq \
        sqlite3
    
    log_success "Required packages installed"
}

# Setup NFS mount for QNAP
setup_nfs_mount() {
    log_info "Setting up QNAP NFS mount..."
    
    # Check if QNAP is accessible
    if ! ping -c 1 192.168.1.60 &>/dev/null; then
        log_warning "QNAP (192.168.1.60) is not accessible. Skipping NFS mount setup."
        return
    fi
    
    # Add to fstab if not already present
    if ! grep -q "$QNAP_MOUNT_POINT" /etc/fstab; then
        echo "192.168.1.60:/infrastructure-backup $QNAP_MOUNT_POINT nfs4 defaults,_netdev,user=$BACKUP_USER 0 0" >> /etc/fstab
        log_success "Added QNAP NFS mount to /etc/fstab"
    fi
    
    # Test mount
    if mount "$QNAP_MOUNT_POINT" 2>/dev/null; then
        log_success "QNAP NFS mount successful"
        umount "$QNAP_MOUNT_POINT"
    else
        log_warning "Could not mount QNAP NFS. Please check QNAP configuration."
    fi
}

# Copy backup scripts
copy_backup_scripts() {
    log_info "Copying backup scripts..."
    
    # Copy main backup script
    cp "$(dirname "$0")/homelab-backup.sh" "$BACKUP_SCRIPT_DIR/"
    chmod 755 "$BACKUP_SCRIPT_DIR/homelab-backup.sh"
    chown root:root "$BACKUP_SCRIPT_DIR/homelab-backup.sh"
    
    # Create backup wrapper script for cron
    cat > "$BACKUP_SCRIPT_DIR/backup-wrapper.sh" << 'EOF'
#!/bin/bash
# Backup wrapper script for cron execution

# Source environment
export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"

# Set umask for secure file creation
umask 027

# Execute backup script with error handling
exec >> /var/log/backup/cron-backup.log 2>&1

echo "=== Backup started at $(date) ==="

# Mount QNAP if not mounted
if ! mountpoint -q /mnt/qnap-backup; then
    mount /mnt/qnap-backup || {
        echo "ERROR: Could not mount QNAP backup storage"
        exit 1
    }
fi

# Execute backup
/opt/backup/homelab-backup.sh "$@"
backup_exit_code=$?

echo "=== Backup completed at $(date) with exit code $backup_exit_code ==="

exit $backup_exit_code
EOF
    
    chmod 755 "$BACKUP_SCRIPT_DIR/backup-wrapper.sh"
    chown root:root "$BACKUP_SCRIPT_DIR/backup-wrapper.sh"
    
    log_success "Backup scripts copied"
}

# Setup cron jobs
setup_cron_jobs() {
    log_info "Setting up backup cron jobs..."
    
    # Create cron file for backup jobs
    cat > /etc/cron.d/homelab-backup << EOF
# Homelab Infrastructure Backup Schedule
# 
# Daily backup at 2:00 AM
0 2 * * * root /opt/backup/backup-wrapper.sh daily

# Weekly backup every Sunday at 3:00 AM
0 3 * * 0 root /opt/backup/backup-wrapper.sh weekly

# Monthly backup on the 1st of each month at 4:00 AM
0 4 1 * * root /opt/backup/backup-wrapper.sh monthly

# Log rotation daily at 1:00 AM
0 1 * * * root /usr/sbin/logrotate /etc/logrotate.d/homelab-backup
EOF
    
    chmod 644 /etc/cron.d/homelab-backup
    
    log_success "Cron jobs configured"
}

# Setup log rotation
setup_log_rotation() {
    log_info "Setting up log rotation..."
    
    cat > /etc/logrotate.d/homelab-backup << EOF
/var/log/backup/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 backup backup
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}
EOF
    
    log_success "Log rotation configured"
}

# Configure AWS CLI for QNAP S3
configure_aws_cli() {
    log_info "Configuring AWS CLI for QNAP S3..."
    
    # Create AWS config directory for backup user
    sudo -u "$BACKUP_USER" mkdir -p "$BACKUP_HOME/.aws"
    
    # Create AWS config
    cat > "$BACKUP_HOME/.aws/config" << EOF
[default]
region = us-east-1
output = json
s3 =
    signature_version = s3v4
    addressing_style = path
EOF
    
    # Create AWS credentials template (to be filled manually)
    cat > "$BACKUP_HOME/.aws/credentials.template" << EOF
[default]
aws_access_key_id = BKP-AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = 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
EOF
    
    chown -R "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.aws"
    chmod 700 "$BACKUP_HOME/.aws"
    chmod 600 "$BACKUP_HOME/.aws/config" "$BACKUP_HOME/.aws/credentials.template"
    
    log_success "AWS CLI configured"
    log_warning "Please copy credentials.template to credentials and update with actual keys"
}

# Setup monitoring for backup jobs
setup_backup_monitoring() {
    log_info "Setting up backup monitoring..."
    
    # Create backup status check script
    cat > "$BACKUP_SCRIPT_DIR/check-backup-status.sh" << 'EOF'
#!/bin/bash
# Backup Status Monitoring Script

BACKUP_LOG="/var/log/backup/homelab-backup.log"
ALERT_EMAIL="admin@yourdomain.com"
LAST_BACKUP_THRESHOLD=86400  # 24 hours in seconds

# Check if backup ran in last 24 hours
if [[ -f "$BACKUP_LOG" ]]; then
    last_backup=$(grep "SUCCESS.*backup completed" "$BACKUP_LOG" | tail -1 | cut -d' ' -f1-2)
    if [[ -n "$last_backup" ]]; then
        last_backup_epoch=$(date -d "$last_backup" +%s 2>/dev/null || echo 0)
        current_epoch=$(date +%s)
        time_diff=$((current_epoch - last_backup_epoch))
        
        if [[ $time_diff -gt $LAST_BACKUP_THRESHOLD ]]; then
            echo "WARNING: Last backup was more than 24 hours ago" | \
                mail -s "Homelab Backup Alert" "$ALERT_EMAIL"
        fi
    else
        echo "ERROR: No successful backup found in logs" | \
            mail -s "Homelab Backup Error" "$ALERT_EMAIL"
    fi
else
    echo "ERROR: Backup log file not found" | \
        mail -s "Homelab Backup Error" "$ALERT_EMAIL"
fi
EOF
    
    chmod 755 "$BACKUP_SCRIPT_DIR/check-backup-status.sh"
    
    # Add monitoring cron job
    echo "0 8 * * * root /opt/backup/check-backup-status.sh" >> /etc/cron.d/homelab-backup
    
    log_success "Backup monitoring configured"
}

# Generate backup documentation
generate_documentation() {
    log_info "Generating backup documentation..."
    
    cat > "$BACKUP_SCRIPT_DIR/README.md" << EOF
# Homelab Backup System

## Overview
Automated backup system for enterprise homelab infrastructure.

## Components Backed Up
- Proxmox VE configuration and VMs
- AdGuard Home configuration (primary and secondary)
- Monitoring stack (Grafana, Prometheus, etc.)
- Dokploy instances (dev, staging, production)
- QNAP configuration
- Network configuration

## Backup Schedule
- **Daily**: 2:00 AM - Full backup of all components
- **Weekly**: 3:00 AM Sunday - Archive of latest daily backup
- **Monthly**: 4:00 AM 1st of month - Archive of latest weekly backup

## Retention Policy
- Daily backups: 7 days
- Weekly backups: 4 weeks
- Monthly backups: 12 months

## Storage Locations
- Primary: QNAP NFS share (/mnt/qnap-backup)
- Offsite: QNAP S3-compatible storage

## Manual Operations

### Run Backup Manually
\`\`\`bash
sudo /opt/backup/homelab-backup.sh daily
sudo /opt/backup/homelab-backup.sh weekly
sudo /opt/backup/homelab-backup.sh monthly
\`\`\`

### Check Backup Status
\`\`\`bash
sudo /opt/backup/check-backup-status.sh
tail -f /var/log/backup/homelab-backup.log
\`\`\`

### Restore Procedures
See restore-procedures.md for detailed restoration instructions.

## Troubleshooting

### Common Issues
1. **NFS Mount Fails**: Check QNAP accessibility and NFS service
2. **SSH Access Denied**: Verify SSH keys are deployed to target hosts
3. **S3 Upload Fails**: Check AWS credentials and QNAP QuObjects service

### Log Locations
- Main backup log: /var/log/backup/homelab-backup.log
- Cron execution log: /var/log/backup/cron-backup.log
- System cron log: /var/log/cron.log

## Configuration Files
- Main script: /opt/backup/homelab-backup.sh
- Wrapper script: /opt/backup/backup-wrapper.sh
- Cron configuration: /etc/cron.d/homelab-backup
- AWS configuration: /home/backup/.aws/
EOF
    
    log_success "Documentation generated"
}

# Test backup system
test_backup_system() {
    log_info "Testing backup system..."
    
    # Test NFS mount
    if mountpoint -q "$QNAP_MOUNT_POINT" || mount "$QNAP_MOUNT_POINT" 2>/dev/null; then
        log_success "NFS mount test passed"
        
        # Test write permissions
        if sudo -u "$BACKUP_USER" touch "$QNAP_MOUNT_POINT/test-file" 2>/dev/null; then
            sudo -u "$BACKUP_USER" rm "$QNAP_MOUNT_POINT/test-file"
            log_success "NFS write test passed"
        else
            log_warning "NFS write test failed - check permissions"
        fi
        
        umount "$QNAP_MOUNT_POINT" 2>/dev/null || true
    else
        log_warning "NFS mount test failed"
    fi
    
    # Test backup script execution
    if "$BACKUP_SCRIPT_DIR/homelab-backup.sh" test &>/dev/null; then
        log_success "Backup script test passed"
    else
        log_warning "Backup script test failed"
    fi
    
    log_success "Backup system testing completed"
}

# Main setup function
main() {
    log_info "Starting backup system setup..."
    
    check_root
    install_packages
    create_backup_user
    setup_directories
    setup_nfs_mount
    copy_backup_scripts
    setup_cron_jobs
    setup_log_rotation
    configure_aws_cli
    setup_backup_monitoring
    generate_documentation
    test_backup_system
    
    log_success "Backup system setup completed!"
    
    echo ""
    echo "=== Next Steps ==="
    echo "1. Distribute SSH public key to Dokploy instances:"
    echo "   cat $BACKUP_HOME/.ssh/id_rsa.pub"
    echo ""
    echo "2. Configure AWS credentials for S3 backup:"
    echo "   cp $BACKUP_HOME/.aws/credentials.template $BACKUP_HOME/.aws/credentials"
    echo "   nano $BACKUP_HOME/.aws/credentials"
    echo ""
    echo "3. Test backup manually:"
    echo "   sudo /opt/backup/homelab-backup.sh test"
    echo ""
    echo "4. Review and customize backup configuration in:"
    echo "   /opt/backup/homelab-backup.sh"
    echo ""
    echo "=== Backup Schedule ==="
    echo "Daily:   2:00 AM"
    echo "Weekly:  3:00 AM Sunday"
    echo "Monthly: 4:00 AM 1st of month"
}

# Execute main function
main "$@"
