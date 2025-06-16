# QNAP TS-433 Configuration for Enterprise Homelab

## Overview

The QNAP TS-433 serves as the central storage hub for the homelab infrastructure, providing NFS shares, S3-compatible object storage, and container hosting capabilities.

## Hardware Specifications

- **Model**: QNAP TS-433 (4-bay NAS)
- **CPU**: ARM Cortex-A55 quad-core 2.0GHz
- **RAM**: 2GB DDR4 (upgradeable to 8GB)
- **Network**: 1x 2.5GbE, 1x 1GbE
- **Storage Bays**: 4x 3.5"/2.5" SATA III
- **Container Support**: Container Station (Docker + LXC)

## Initial Configuration

### 1. Network Setup

**Primary Network Interface:**
```yaml
Interface: eth0 (2.5GbE)
IP Address: 192.168.1.60/24
Gateway: 192.168.1.1
DNS Primary: 192.168.1.20
DNS Secondary: 192.168.1.21
Domain: lab.local
```

**Secondary Network Interface (if using link aggregation):**
```yaml
Interface: eth1 (1GbE)
IP Address: 192.168.1.61/24
Bonding Mode: 802.3ad (LACP)
```

### 2. Storage Pool Configuration

**RAID Configuration:**
```yaml
Storage Pool: "HomelabPool"
RAID Level: RAID 5 (recommended for 4 drives)
Drives: 4x 4TB NAS-grade drives (WD Red Pro or Seagate IronWolf Pro)
Hot Spare: Configure if using 5+ drives
```

**Volume Layout:**
```yaml
Volumes:
  - Name: "Infrastructure"
    Size: 200GB
    Purpose: System and infrastructure data
    
  - Name: "ProxmoxStorage"
    Size: 1TB
    Purpose: VM images, templates, backups
    
  - Name: "DokployData"
    Size: 800GB
    Purpose: Application persistent data
    
  - Name: "Backups"
    Size: 1TB
    Purpose: Infrastructure and application backups
    
  - Name: "Shared"
    Size: Remaining space
    Purpose: General file storage and media
```

## NFS Configuration

### 1. Enable NFS Service

**Navigate to:** Control Panel → Network Services → NFS Service

```yaml
NFS Service Settings:
  Enable NFSv4: ✓
  Enable NFSv3: ✓
  Enable NFSv2: ✗
  Security Level: sys
  Default NFSv4 Domain: lab.local
  Enable Kerberos: ✗
  
Performance Settings:
  Max read/write block size: 1048576 (1MB)
  Number of NFS threads: 8
  Enable TCP: ✓
  Enable UDP: ✗
```

### 2. Create NFS Shares

**Navigate to:** Control Panel → Shared Folders

#### Proxmox Storage Shares

**VM Storage Share:**
```yaml
Folder Name: proxmox-vm-storage
Path: /Infrastructure/proxmox/vm-storage
Description: Proxmox VM images and templates

NFS Permissions:
  - Host/IP: 192.168.1.0/24
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
    Secure: ✓
```

**Backup Storage Share:**
```yaml
Folder Name: proxmox-backup
Path: /Backups/proxmox
Description: Proxmox backup storage

NFS Permissions:
  - Host/IP: 192.168.1.0/24
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
    Secure: ✓
```

#### Dokploy Application Shares

**Development Environment:**
```yaml
Folder Name: dokploy-dev
Path: /DokployData/dev
Description: Dokploy development environment data

NFS Permissions:
  - Host/IP: 192.168.1.30/32
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
```

**Staging Environment:**
```yaml
Folder Name: dokploy-staging
Path: /DokployData/staging
Description: Dokploy staging environment data

NFS Permissions:
  - Host/IP: 192.168.1.40/32
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
```

**Production Environment:**
```yaml
Folder Name: dokploy-prod
Path: /DokployData/prod
Description: Dokploy production environment data

NFS Permissions:
  - Host/IP: 192.168.1.50/32
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
```

#### Monitoring and Logs

**Monitoring Data:**
```yaml
Folder Name: monitoring-data
Path: /Infrastructure/monitoring
Description: Prometheus, Grafana, and log data

NFS Permissions:
  - Host/IP: 192.168.1.26/32
    Access Rights: Read/Write
    Sync: Sync
    No Root Squash: ✓
```

## S3-Compatible Object Storage (QuObjects)

### 1. Install QuObjects

**Navigate to:** App Center → Search "QuObjects" → Install

### 2. Configure QuObjects

**Basic Configuration:**
```yaml
Service Settings:
  HTTPS Port: 443
  HTTP Port: 8080
  SSL Certificate: Generate self-signed or import custom
  
Access Control:
  Enable Authentication: ✓
  Default Region: us-east-1
  
Storage Backend:
  Storage Pool: HomelabPool
  Volume: DokployData
  Path: /S3Storage
```

### 3. Create S3 Buckets

**Navigate to:** QuObjects → Buckets

```yaml
Buckets:
  - Name: dokploy-dev-storage
    Access Level: Private
    Versioning: Enabled
    Purpose: Development environment object storage
    
  - Name: dokploy-staging-storage
    Access Level: Private
    Versioning: Enabled
    Purpose: Staging environment object storage
    
  - Name: dokploy-prod-storage
    Access Level: Private
    Versioning: Enabled
    Purpose: Production environment object storage
    
  - Name: infrastructure-backup
    Access Level: Private
    Versioning: Enabled
    Purpose: Infrastructure configuration backups
    
  - Name: application-backups
    Access Level: Private
    Versioning: Enabled
    Purpose: Application-specific backups
    
  - Name: monitoring-exports
    Access Level: Private
    Versioning: Disabled
    Purpose: Monitoring data exports
```

### 4. Configure S3 Users and Access Keys

**Navigate to:** QuObjects → Users

```yaml
Users:
  - Username: dokploy-dev-user
    Access Key: DEV-AKIAIOSFODNN7EXAMPLE
    Secret Key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYDEVELOPMENT
    Permissions:
      - Bucket: dokploy-dev-storage
        Actions: Read, Write, Delete
        
  - Username: dokploy-staging-user
    Access Key: STG-AKIAIOSFODNN7EXAMPLE
    Secret Key: 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
    Permissions:
      - Bucket: dokploy-staging-storage
        Actions: Read, Write, Delete
        
  - Username: dokploy-prod-user
    Access Key: PRD-AKIAIOSFODNN7EXAMPLE
    Secret Key: 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
    Permissions:
      - Bucket: dokploy-prod-storage
        Actions: Read, Write, Delete
        
  - Username: backup-service
    Access Key: BKP-AKIAIOSFODNN7EXAMPLE
    Secret Key: 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
    Permissions:
      - Bucket: infrastructure-backup
        Actions: Read, Write, Delete
      - Bucket: application-backups
        Actions: Read, Write, Delete
        
  - Username: monitoring-service
    Access Key: MON-AKIAIOSFODNN7EXAMPLE
    Secret Key: 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
    Permissions:
      - Bucket: monitoring-exports
        Actions: Read, Write, Delete
```

## Container Station Configuration

### 1. Enable Container Station

**Navigate to:** App Center → Search "Container Station" → Install

### 2. Configure Container Settings

**Basic Configuration:**
```yaml
Container Settings:
  Enable Docker: ✓
  Enable LXD: ✓
  Docker Registry: docker.io
  
Network Configuration:
  Container Network: 172.18.0.0/16
  Enable SSH: ✓
  SSH Port: 2222
  
Resource Limits:
  CPU Limit: 80% (reserve 20% for NAS functions)
  Memory Limit: 1.5GB (reserve 0.5GB for NAS)
```

### 3. Deploy Infrastructure Containers

#### Nginx Reverse Proxy for Internal Services

```yaml
# docker-compose.yml for internal services
version: '3.8'

services:
  nginx-internal:
    image: nginx:alpine
    container_name: nginx-internal
    ports:
      - "8080:80"
      - "8443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
    networks:
      - qnap-internal
    restart: unless-stopped

networks:
  qnap-internal:
    driver: bridge
    ipam:
      config:
        - subnet: 172.19.0.0/24
```

#### Backup Services Container

```yaml
# Automated backup services
version: '3.8'

services:
  backup-scheduler:
    image: alpine:latest
    container_name: backup-scheduler
    volumes:
      - /share/Backups:/backups
      - /share/DokployData:/source-data:ro
      - ./backup-scripts:/scripts:ro
    environment:
      - BACKUP_SCHEDULE=0 2 * * *  # Daily at 2 AM
    command: >
      sh -c "
        apk add --no-cache dcron rsync &&
        echo '0 2 * * * /scripts/daily-backup.sh' | crontab - &&
        crond -f -d 8
      "
    networks:
      - qnap-internal
    restart: unless-stopped
```

## Performance Optimization

### 1. Network Performance

**Enable Jumbo Frames (if supported by network):**
```yaml
Network Settings:
  MTU Size: 9000
  Flow Control: Enabled
  
Quality of Service:
  Enable Adaptive QoS: ✓
  Priority Settings:
    NFS Traffic: High
    S3/HTTP Traffic: Medium
    Container Traffic: Medium
    Backup Traffic: Low
```

**Link Aggregation (if using multiple ports):**
```yaml
Network Aggregation:
  Type: IEEE 802.3ad (LACP)
  Ports: [eth0, eth1]
  Mode: Balance-XOR
  Hash Policy: layer2+3
```

### 2. Storage Performance

**SSD Cache (if SSDs available):**
```yaml
Cache Acceleration:
  Cache Type: Read/Write
  SSD1: M.2 SSD (500GB)
  SSD2: M.2 SSD (500GB) - for redundancy
  Cache Mode: RAID 1
```

**Snapshot Configuration:**
```yaml
Snapshot Settings:
  Enable Snapshots: ✓
  Snapshot Schedule:
    Frequency: Every 4 hours
    Retention: 
      - Hourly: 24 snapshots
      - Daily: 7 snapshots
      - Weekly: 4 snapshots
      - Monthly: 12 snapshots
```

### 3. NFS Performance Tuning

**Advanced NFS Settings:**
```yaml
NFS Performance:
  Read Block Size: 1048576 (1MB)
  Write Block Size: 1048576 (1MB)
  Read Ahead: 128KB
  Async: Enabled (for better performance)
  Compression: Disabled (let clients handle)
```

## Security Configuration

### 1. Access Control

**User Management:**
```yaml
User Groups:
  - administrators: Full access to all shares
  - infrastructure: Access to infrastructure shares only
  - developers: Access to development shares only
  - backup-service: Access to backup shares only
  - monitoring: Read-only access to monitoring data
```

**Network Access Protection:**
```yaml
Security Settings:
  Enable Auto IP Blocking: ✓
  Block Threshold: 5 failed attempts
  Block Duration: 30 minutes
  
  Allowed Networks:
    - 192.168.1.0/24 (Main homelab network)
    - 10.10.10.0/24 (VPN clients)
    
  Blocked Networks:
    - 0.0.0.0/0 (Default deny, then allow specific)
```

### 2. SSL/TLS Configuration

**Certificate Management:**
```yaml
SSL Settings:
  Certificate Type: Let's Encrypt or Self-signed
  Domain Name: qnap.lab.local
  Auto-renewal: ✓
  Force HTTPS: ✓
  HSTS: Enabled
  TLS Version: 1.2+ only
```

### 3. Firewall Rules

**Built-in Firewall:**
```yaml
Firewall Rules:
  - Allow SSH from 192.168.1.0/24 on port 22
  - Allow HTTPS from 192.168.1.0/24 on port 443
  - Allow NFS from 192.168.1.0/24 on ports 111,2049
  - Allow S3 from 192.168.1.0/24 on port 8080
  - Deny all other traffic
```

## Monitoring and Maintenance

### 1. System Monitoring

**Health Monitoring:**
```yaml
Monitoring Settings:
  Enable Real-time Monitoring: ✓
  Historical Data Retention: 1 year
  
  Alert Thresholds:
    CPU Usage: >85% for 5 minutes
    Memory Usage: >90% for 5 minutes
    Storage Usage: >90%
    Temperature: >65°C
    
  Notification Methods:
    Email: ✓
    SNMP: ✓
    Syslog: ✓
```

### 2. Backup Strategy

**Local Backup:**
```yaml
Backup Configuration:
  Local Snapshots: Every 4 hours, retain 7 days
  External Backup: Daily to external drive
  Cloud Backup: Weekly to cloud storage (optional)
  
  Backup Verification:
    Integrity Checks: Daily
    Test Restores: Weekly
```

### 3. Maintenance Tasks

**Scheduled Maintenance:**
```yaml
Daily Tasks:
  - Health checks
  - Log rotation
  - Backup verification
  
Weekly Tasks:
  - Firmware updates (if available)
  - Performance review
  - Security log analysis
  
Monthly Tasks:
  - Full system backup
  - Storage optimization
  - Hardware health check
```

## Integration with Other Services

### 1. Proxmox Integration

**Add QNAP as Storage:**
```bash
# On Proxmox host
pvesm add nfs qnap-vm-storage \
  --server 192.168.1.60 \
  --export /proxmox-vm-storage \
  --content images,vztmpl,iso,backup \
  --options vers=4
```

### 2. Dokploy Integration

**Mount NFS in Dokploy VMs:**
```bash
# Add to /etc/fstab on each Dokploy VM
192.168.1.60:/dokploy-dev /mnt/shared-storage nfs4 defaults,_netdev 0 0
```

### 3. Monitoring Integration

**SNMP Configuration for Prometheus:**
```yaml
# Add to prometheus.yml
- job_name: 'qnap'
  static_configs:
    - targets: ['192.168.1.60:161']
  metrics_path: /snmp
  params:
    module: [qnap]
```

## Troubleshooting

### Common Issues

**NFS Mount Failures:**
```bash
# Check NFS service status
systemctl status nfs-server

# Test NFS connectivity
showmount -e 192.168.1.60

# Verify permissions
ls -la /share/
```

**S3 Connectivity Issues:**
```bash
# Test S3 endpoint
curl -k https://192.168.1.60:443

# Check QuObjects logs
tail -f /var/log/quobjects/quobjects.log
```

**Performance Issues:**
```bash
# Check system resources
htop
iotop
nethogs

# Monitor disk I/O
iostat -x 1 5

# Check network throughput
iperf3 -s  # On QNAP
iperf3 -c 192.168.1.60 -t 30  # From client
```

This QNAP configuration provides enterprise-grade storage capabilities for the entire homelab infrastructure while maintaining high performance and security.
