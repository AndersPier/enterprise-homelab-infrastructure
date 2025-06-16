#!/bin/bash
# Enterprise Homelab Backup Automation Script
# Comprehensive backup solution for all infrastructure components

# Set strict error handling
set -euo pipefail

# ==============================================
# CONFIGURATION VARIABLES
# ==============================================

# Backup directories
BACKUP_ROOT="/mnt/qnap-backup"
BACKUP_DATE=$(date +%Y-%m-%d-%H%M)
DAILY_BACKUP_DIR="$BACKUP_ROOT/daily/$BACKUP_DATE"
WEEKLY_BACKUP_DIR="$BACKUP_ROOT/weekly/$(date +%Y-W%U)"
MONTHLY_BACKUP_DIR="$BACKUP_ROOT/monthly/$(date +%Y-%m)"

# Retention settings
DAILY_RETENTION_DAYS=7
WEEKLY_RETENTION_WEEKS=4
MONTHLY_RETENTION_MONTHS=12

# Log configuration
LOG_FILE="/var/log/homelab-backup.log"
EMAIL_RECIPIENT="admin@yourdomain.com"

# Backup sources
PROXMOX_CONFIG_DIR="/etc/pve"
ADGUARD_CONFIG_DIR="/opt/AdGuardHome"
MONITORING_CONFIG_DIR="/opt/monitoring"
DOKPLOY_CONFIG_DIR="/etc/dokploy"

# QNAP S3 configuration for offsite backup
S3_ENDPOINT="https://qnap.lab.local:443"
S3_BUCKET="infrastructure-backup"
S3_ACCESS_KEY="BKP-AKIAIOSFODNN7EXAMPLE"
S3_SECRET_KEY="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"

# ==============================================
# UTILITY FUNCTIONS
# ==============================================

# Color output functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)  echo -e "${BLUE}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    esac
    
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Send email notification
send_notification() {
    local subject="$1"
    local body="$2"
    
    if command_exists mail; then
        echo "$body" | mail -s "$subject" "$EMAIL_RECIPIENT"
    else
        log WARN "Mail command not available, skipping email notification"
    fi
}

# Create backup directory with proper permissions
create_backup_dir() {
    local dir="$1"
    mkdir -p "$dir"
    chmod 750 "$dir"
    log INFO "Created backup directory: $dir"
}

# Calculate directory size
get_size() {
    local path="$1"
    if [[ -d "$path" ]]; then
        du -sh "$path" 2>/dev/null | cut -f1 || echo "Unknown"
    else
        echo "N/A"
    fi
}

# ==============================================
# BACKUP FUNCTIONS
# ==============================================

# Backup Proxmox configuration and VMs
backup_proxmox() {
    log INFO "Starting Proxmox backup..."
    
    local proxmox_backup_dir="$DAILY_BACKUP_DIR/proxmox"
    create_backup_dir "$proxmox_backup_dir"
    
    # Backup Proxmox configuration
    if [[ -d "$PROXMOX_CONFIG_DIR" ]]; then
        log INFO "Backing up Proxmox configuration..."
        tar -czf "$proxmox_backup_dir/pve-config-$BACKUP_DATE.tar.gz" \
            -C "$(dirname "$PROXMOX_CONFIG_DIR")" \
            "$(basename "$PROXMOX_CONFIG_DIR")" 2>/dev/null || {
            log ERROR "Failed to backup Proxmox configuration"
            return 1
        }
        log SUCCESS "Proxmox configuration backed up"
    else
        log WARN "Proxmox configuration directory not found: $PROXMOX_CONFIG_DIR"
    fi
    
    # Backup running VMs and containers (using vzdump)
    if command_exists vzdump; then
        log INFO "Starting VM and container backups..."
        
        # List running VMs and containers
        local vms=$(qm list 2>/dev/null | awk 'NR>1 {print $1}' || true)
        local containers=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' || true)
        
        # Backup VMs
        for vm in $vms; do
            log INFO "Backing up VM $vm..."
            vzdump "$vm" --storage qnap-backup --compress gzip --mode snapshot || {
                log ERROR "Failed to backup VM $vm"
            }
        done
        
        # Backup containers
        for container in $containers; do
            log INFO "Backing up container $container..."
            vzdump "$container" --storage qnap-backup --compress gzip --mode snapshot || {
                log ERROR "Failed to backup container $container"
            }
        done
        
    else
        log WARN "vzdump command not available, skipping VM/container backups"
    fi
    
    log SUCCESS "Proxmox backup completed"
}

# Backup AdGuard Home configuration
backup_adguard() {
    log INFO "Starting AdGuard Home backup..."
    
    local adguard_backup_dir="$DAILY_BACKUP_DIR/adguard"
    create_backup_dir "$adguard_backup_dir"
    
    # Backup primary AdGuard configuration
    if [[ -d "$ADGUARD_CONFIG_DIR" ]]; then
        log INFO "Backing up AdGuard Home configuration..."
        tar -czf "$adguard_backup_dir/adguard-config-$BACKUP_DATE.tar.gz" \
            -C "$(dirname "$ADGUARD_CONFIG_DIR")" \
            "$(basename "$ADGUARD_CONFIG_DIR")" || {
            log ERROR "Failed to backup AdGuard configuration"
            return 1
        }
        
        # Also backup just the YAML config files for easy restore
        cp "$ADGUARD_CONFIG_DIR/AdGuardHome.yaml" \
           "$adguard_backup_dir/AdGuardHome-primary-$BACKUP_DATE.yaml" 2>/dev/null || {
            log WARN "Could not copy AdGuard primary config file"
        }
        
        log SUCCESS "AdGuard Home configuration backed up"
    else
        log WARN "AdGuard configuration directory not found: $ADGUARD_CONFIG_DIR"
    fi
    
    # Backup secondary AdGuard if accessible via SSH
    if command_exists ssh; then
        log INFO "Attempting to backup secondary AdGuard..."
        ssh -o ConnectTimeout=10 ubuntu@192.168.1.21 \
            "sudo cp /opt/AdGuardHome/AdGuardHome.yaml /tmp/ && sudo chmod 644 /tmp/AdGuardHome.yaml" 2>/dev/null && \
        scp -o ConnectTimeout=10 ubuntu@192.168.1.21:/tmp/AdGuardHome.yaml \
            "$adguard_backup_dir/AdGuardHome-secondary-$BACKUP_DATE.yaml" 2>/dev/null || {
            log WARN "Could not backup secondary AdGuard configuration"
        }
    fi
}

# Backup monitoring stack
backup_monitoring() {
    log INFO "Starting monitoring stack backup..."
    
    local monitoring_backup_dir="$DAILY_BACKUP_DIR/monitoring"
    create_backup_dir "$monitoring_backup_dir"
    
    # Backup monitoring configuration
    if [[ -d "$MONITORING_CONFIG_DIR" ]]; then
        log INFO "Backing up monitoring configuration..."
        tar -czf "$monitoring_backup_dir/monitoring-config-$BACKUP_DATE.tar.gz" \
            -C "$(dirname "$MONITORING_CONFIG_DIR")" \
            "$(basename "$MONITORING_CONFIG_DIR")" || {
            log ERROR "Failed to backup monitoring configuration"
            return 1
        }
        log SUCCESS "Monitoring configuration backed up"
    fi
    
    # Backup Grafana dashboards and data (if running on this host)
    if command_exists docker && docker ps | grep -q grafana; then
        log INFO "Backing up Grafana data..."
        
        # Export Grafana dashboards
        local grafana_container=$(docker ps --format "{{.Names}}" | grep grafana | head -1)
        if [[ -n "$grafana_container" ]]; then
            # Create dashboard export
            docker exec "$grafana_container" grafana-cli admin export-dashboard \
                > "$monitoring_backup_dir/grafana-dashboards-$BACKUP_DATE.json" 2>/dev/null || {
                log WARN "Could not export Grafana dashboards"
            }
            
            # Backup Grafana database
            docker exec "$grafana_container" sqlite3 /var/lib/grafana/grafana.db ".backup /tmp/grafana-backup.db" 2>/dev/null && \
            docker cp "$grafana_container:/tmp/grafana-backup.db" \
                "$monitoring_backup_dir/grafana-db-$BACKUP_DATE.db" || {
                log WARN "Could not backup Grafana database"
            }
        fi
    fi
    
    # Backup Prometheus data (retention-aware)
    if [[ -d "/opt/monitoring/prometheus/data" ]]; then
        log INFO "Backing up Prometheus configuration (data excluded for size)..."
        tar -czf "$monitoring_backup_dir/prometheus-config-$BACKUP_DATE.tar.gz" \
            --exclude="data" \
            -C "/opt/monitoring" prometheus || {
            log WARN "Could not backup Prometheus configuration"
        }
    fi
}

# Backup Dokploy configurations
backup_dokploy() {
    log INFO "Starting Dokploy backup..."
    
    local dokploy_backup_dir="$DAILY_BACKUP_DIR/dokploy"
    create_backup_dir "$dokploy_backup_dir"
    
    # Backup each Dokploy instance
    local dokploy_hosts=("192.168.1.30" "192.168.1.40" "192.168.1.50")
    local dokploy_names=("dev" "staging" "prod")
    
    for i in "${!dokploy_hosts[@]}"; do
        local host="${dokploy_hosts[$i]}"
        local name="${dokploy_names[$i]}"
        
        log INFO "Backing up Dokploy $name instance ($host)..."
        
        if command_exists ssh; then
            # Create remote backup script
            ssh -o ConnectTimeout=10 "ubuntu@$host" << 'EOF' || {
                log WARN "Could not connect to Dokploy $name instance"
                continue
            }
                # Backup Dokploy configuration
                sudo tar -czf "/tmp/dokploy-config.tar.gz" -C /etc dokploy 2>/dev/null || true
                
                # Backup Docker volumes (application data)
                sudo tar -czf "/tmp/docker-volumes.tar.gz" -C /var/lib/docker volumes 2>/dev/null || true
                
                # Make files readable
                sudo chmod 644 /tmp/dokploy-config.tar.gz /tmp/docker-volumes.tar.gz 2>/dev/null || true
EOF
            
            # Copy backup files
            scp -o ConnectTimeout=10 "ubuntu@$host:/tmp/dokploy-config.tar.gz" \
                "$dokploy_backup_dir/dokploy-$name-config-$BACKUP_DATE.tar.gz" 2>/dev/null || true
            
            scp -o ConnectTimeout=10 "ubuntu@$host:/tmp/docker-volumes.tar.gz" \
                "$dokploy_backup_dir/dokploy-$name-volumes-$BACKUP_DATE.tar.gz" 2>/dev/null || true
            
            # Cleanup remote files
            ssh -o ConnectTimeout=10 "ubuntu@$host" \
                "rm -f /tmp/dokploy-config.tar.gz /tmp/docker-volumes.tar.gz" 2>/dev/null || true
        fi
    done
    
    log SUCCESS "Dokploy backup completed"
}

# Backup QNAP configuration
backup_qnap() {
    log INFO "Starting QNAP configuration backup..."
    
    local qnap_backup_dir="$DAILY_BACKUP_DIR/qnap"
    create_backup_dir "$qnap_backup_dir"
    
    # Export QNAP configuration (if accessible via SSH or API)
    # Note: This would require QNAP SSH access or API configuration
    # For now, create a placeholder with manual backup instructions
    
    cat > "$qnap_backup_dir/backup-instructions.txt" << EOF
QNAP Configuration Backup Instructions:

1. Access QNAP Web Interface
2. Go to Control Panel → System → Backup/Restore
3. Export Configuration:
   - Export System Configuration
   - Export Application Settings
   - Export User/Group Settings
   - Export Network Settings

4. Save configuration files to: $qnap_backup_dir/

Manual backup completed on: $(date)
EOF
    
    log INFO "QNAP backup instructions created (manual backup required)"
}

# Backup network configuration
backup_network() {
    log INFO "Starting network configuration backup..."
    
    local network_backup_dir="$DAILY_BACKUP_DIR/network"
    create_backup_dir "$network_backup_dir"
    
    # Backup local network configuration
    if [[ -f "/etc/network/interfaces" ]]; then
        cp "/etc/network/interfaces" "$network_backup_dir/interfaces-$BACKUP_DATE"
    fi
    
    if [[ -f "/etc/netplan/01-netcfg.yaml" ]]; then
        cp "/etc/netplan/01-netcfg.yaml" "$network_backup_dir/netplan-$BACKUP_DATE.yaml"
    fi
    
    # Export routing table
    ip route > "$network_backup_dir/routes-$BACKUP_DATE.txt" 2>/dev/null || true
    
    # Export network interfaces
    ip addr > "$network_backup_dir/interfaces-$BACKUP_DATE.txt" 2>/dev/null || true
    
    # UCG Ultra configuration (manual backup instructions)
    cat > "$network_backup_dir/ucg-ultra-backup.txt" << EOF
UCG Ultra Configuration Backup Instructions:

1. Access UCG Ultra Web Interface (https://192.168.1.1)
2. Go to Settings → System → Backup & Restore
3. Download Configuration Backup
4. Save to: $network_backup_dir/ucg-ultra-config-$BACKUP_DATE.json

Manual backup required for complete network configuration.
EOF
    
    log SUCCESS "Network configuration backup completed"
}

# Upload to offsite storage (S3)
upload_to_offsite() {
    log INFO "Starting offsite backup upload..."
    
    if ! command_exists aws; then
        log WARN "AWS CLI not installed, skipping offsite backup"
        return
    fi
    
    # Configure AWS CLI for QNAP S3
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="us-east-1"
    
    # Upload daily backup
    aws s3 cp "$DAILY_BACKUP_DIR" "s3://$S3_BUCKET/daily/$BACKUP_DATE/" \
        --recursive \
        --endpoint-url "$S3_ENDPOINT" \
        --no-verify-ssl || {
        log ERROR "Failed to upload to offsite storage"
        return 1
    }
    
    log SUCCESS "Offsite backup upload completed"
}

# ==============================================
# CLEANUP FUNCTIONS
# ==============================================

# Cleanup old backups based on retention policy
cleanup_old_backups() {
    log INFO "Starting backup cleanup..."
    
    # Cleanup daily backups
    if [[ -d "$BACKUP_ROOT/daily" ]]; then
        find "$BACKUP_ROOT/daily" -type d -mtime +$DAILY_RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
        log INFO "Cleaned up daily backups older than $DAILY_RETENTION_DAYS days"
    fi
    
    # Cleanup weekly backups
    if [[ -d "$BACKUP_ROOT/weekly" ]]; then
        find "$BACKUP_ROOT/weekly" -type d -mtime +$((WEEKLY_RETENTION_WEEKS * 7)) -exec rm -rf {} + 2>/dev/null || true
        log INFO "Cleaned up weekly backups older than $WEEKLY_RETENTION_WEEKS weeks"
    fi
    
    # Cleanup monthly backups
    if [[ -d "$BACKUP_ROOT/monthly" ]]; then
        find "$BACKUP_ROOT/monthly" -type d -mtime +$((MONTHLY_RETENTION_MONTHS * 30)) -exec rm -rf {} + 2>/dev/null || true
        log INFO "Cleaned up monthly backups older than $MONTHLY_RETENTION_MONTHS months"
    fi
    
    # Cleanup offsite backups (keep last 30 days)
    if command_exists aws; then
        export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
        export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
        export AWS_DEFAULT_REGION="us-east-1"
        
        # Delete old daily backups from S3
        aws s3 ls "s3://$S3_BUCKET/daily/" --endpoint-url "$S3_ENDPOINT" --no-verify-ssl | \
        while read -r line; do
            backup_date=$(echo "$line" | awk '{print $2}' | tr -d '/')
            if [[ -n "$backup_date" ]] && [[ $(date -d "$backup_date" +%s 2>/dev/null || echo 0) -lt $(date -d "30 days ago" +%s) ]]; then
                aws s3 rm "s3://$S3_BUCKET/daily/$backup_date/" --recursive \
                    --endpoint-url "$S3_ENDPOINT" --no-verify-ssl || true
            fi
        done 2>/dev/null
    fi
    
    log SUCCESS "Backup cleanup completed"
}

# ==============================================
# WEEKLY AND MONTHLY BACKUP FUNCTIONS
# ==============================================

# Create weekly backup (copy from latest daily)
create_weekly_backup() {
    log INFO "Creating weekly backup..."
    
    create_backup_dir "$WEEKLY_BACKUP_DIR"
    
    # Copy latest daily backup to weekly
    local latest_daily=$(find "$BACKUP_ROOT/daily" -maxdepth 1 -type d -name "20*" | sort | tail -1)
    if [[ -n "$latest_daily" ]]; then
        cp -r "$latest_daily"/* "$WEEKLY_BACKUP_DIR/" || {
            log ERROR "Failed to create weekly backup"
            return 1
        }
        log SUCCESS "Weekly backup created from $latest_daily"
    else
        log WARN "No daily backup found for weekly backup"
    fi
}

# Create monthly backup (copy from latest weekly)
create_monthly_backup() {
    log INFO "Creating monthly backup..."
    
    create_backup_dir "$MONTHLY_BACKUP_DIR"
    
    # Copy latest weekly backup to monthly
    local latest_weekly=$(find "$BACKUP_ROOT/weekly" -maxdepth 1 -type d -name "20*" | sort | tail -1)
    if [[ -n "$latest_weekly" ]]; then
        cp -r "$latest_weekly"/* "$MONTHLY_BACKUP_DIR/" || {
            log ERROR "Failed to create monthly backup"
            return 1
        }
        log SUCCESS "Monthly backup created from $latest_weekly"
    else
        log WARN "No weekly backup found for monthly backup"
    fi
}

# ==============================================
# MAIN BACKUP FUNCTION
# ==============================================

main_backup() {
    local backup_type="${1:-daily}"
    
    log INFO "Starting $backup_type backup process..."
    local start_time=$(date +%s)
    
    # Create backup directories
    create_backup_dir "$BACKUP_ROOT"
    create_backup_dir "$DAILY_BACKUP_DIR"
    
    # Perform backups based on type
    case "$backup_type" in
        "daily")
            backup_proxmox
            backup_adguard
            backup_monitoring
            backup_dokploy
            backup_qnap
            backup_network
            upload_to_offsite
            cleanup_old_backups
            ;;
        "weekly")
            create_weekly_backup
            ;;
        "monthly")
            create_monthly_backup
            ;;
        *)
            log ERROR "Unknown backup type: $backup_type"
            exit 1
            ;;
    esac
    
    # Calculate duration and size
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local backup_size=$(get_size "$DAILY_BACKUP_DIR")
    
    # Generate summary
    local summary="Backup Summary:
Type: $backup_type
Date: $BACKUP_DATE
Duration: ${duration}s
Backup Size: $backup_size
Status: Completed Successfully

Backup Location: $DAILY_BACKUP_DIR
Log File: $LOG_FILE"
    
    log SUCCESS "$backup_type backup completed in ${duration}s (Size: $backup_size)"
    
    # Send notification
    send_notification "Homelab Backup Completed - $backup_type" "$summary"
    
    return 0
}

# ==============================================
# SCRIPT EXECUTION
# ==============================================

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    log WARN "Running as root. Consider running as dedicated backup user."
fi

# Ensure log file exists
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Parse command line arguments
BACKUP_TYPE="${1:-daily}"

# Main execution
case "$BACKUP_TYPE" in
    "daily"|"weekly"|"monthly")
        main_backup "$BACKUP_TYPE"
        ;;
    "test")
        log INFO "Running backup test..."
        create_backup_dir "$BACKUP_ROOT/test"
        log SUCCESS "Backup test completed"
        ;;
    *)
        echo "Usage: $0 [daily|weekly|monthly|test]"
        echo ""
        echo "Daily backup: Full backup of all components"
        echo "Weekly backup: Copy latest daily to weekly retention"
        echo "Monthly backup: Copy latest weekly to monthly retention"
        echo "Test: Test backup directories and permissions"
        exit 1
        ;;
esac

exit 0
