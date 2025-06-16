# Monitoring Stack Deployment Guide

## Overview

This comprehensive monitoring stack provides enterprise-grade observability for your homelab infrastructure, including metrics collection, log aggregation, alerting, and visualization.

## Components

| Service | Port | Purpose | Access URL |
|---------|------|---------|------------|
| **Grafana** | 3000 | Dashboards & Visualization | http://monitoring.lab.local:3000 |
| **Prometheus** | 9090 | Metrics Collection | http://monitoring.lab.local:9090 |
| **AlertManager** | 9093 | Alert Routing | http://monitoring.lab.local:9093 |
| **Loki** | 3100 | Log Aggregation | http://monitoring.lab.local:3100 |
| **Uptime Kuma** | 3001 | Service Monitoring | http://monitoring.lab.local:3001 |
| **Portainer** | 9000 | Container Management | http://monitoring.lab.local:9000 |
| **Dozzle** | 9999 | Docker Log Viewer | http://monitoring.lab.local:9999 |
| **Speedtest** | 8765 | Internet Speed Tests | http://monitoring.lab.local:8765 |
| **Ntopng** | 3002 | Network Analysis | http://monitoring.lab.local:3002 |

## Prerequisites

- [ ] Docker and Docker Compose installed
- [ ] 4GB+ RAM available for monitoring host
- [ ] 50GB+ storage space for metrics and logs
- [ ] Network connectivity to all monitored systems
- [ ] SMTP credentials for email alerts (optional)

## Quick Start

### 1. Clone Repository and Navigate
```bash
git clone https://github.com/AndersPier/enterprise-homelab-infrastructure.git
cd enterprise-homelab-infrastructure/monitoring
```

### 2. Configure Environment Variables
```bash
# Copy and edit environment template
cp .env.example .env
vim .env

# Required variables:
# GRAFANA_ADMIN_PASSWORD=your-secure-password
# SMTP_FROM=alerts@yourdomain.com
# SMTP_USERNAME=alerts@yourdomain.com
# SMTP_PASSWORD=your-app-password
# DOMAIN=yourdomain.com
```

### 3. Update IP Addresses
Edit configuration files to match your network:

**Prometheus configuration:**
```bash
vim prometheus/prometheus.yml
# Update all IP addresses under static_configs
```

**AlertManager configuration:**
```bash
vim alertmanager/alertmanager.yml
# Update email addresses and SMTP settings
```

### 4. Deploy Stack
```bash
# Create required directories
mkdir -p {grafana,prometheus,loki,alertmanager}/data

# Set permissions
sudo chown -R 472:472 grafana/data  # Grafana user ID
sudo chown -R 65534:65534 prometheus/data  # nobody user
sudo chown -R 10001:10001 loki/data  # Loki user

# Start all services
docker-compose up -d

# Verify deployment
docker-compose ps
docker-compose logs -f grafana
```

### 5. Initial Setup

**Access Grafana:**
1. Navigate to http://monitoring.lab.local:3000
2. Login: admin / homelab123! (change immediately)
3. Datasources should be auto-configured
4. Import dashboards from the community

**Configure Uptime Kuma:**
1. Navigate to http://monitoring.lab.local:3001
2. Create admin account
3. Add monitors for critical services

## Configuration Details

### Network Monitoring Configuration

**Update Prometheus targets** in `prometheus/prometheus.yml`:
```yaml
scrape_configs:
  - job_name: 'node-exporter'
    static_configs:
      - targets:
        - '192.168.1.10:9100'  # Proxmox host
        - '192.168.1.20:9100'  # AdGuard primary
        - '192.168.1.30:9100'  # Dokploy dev
        # Add your actual IPs
```

**Configure Blackbox monitoring** for endpoint checks:
```yaml
# Already configured in blackbox/blackbox.yml
# Update target URLs in prometheus.yml under blackbox-http job
```

### Alert Configuration

**Email alerts setup** in `alertmanager/alertmanager.yml`:
```yaml
global:
  smtp_smarthost: 'smtp.gmail.com:587'
  smtp_from: 'alerts@yourdomain.com'
  smtp_auth_username: 'alerts@yourdomain.com'
  smtp_auth_password: 'your-app-password'  # Use app-specific password
```

**Critical alert thresholds:**
- Host down: 1 minute
- High CPU: >85% for 5 minutes
- High memory: >90% for 5 minutes
- High disk: >85% for 5 minutes
- DNS failure: 1 minute

### Log Collection Setup

**Install Node Exporter** on monitored systems:
```bash
# On each system you want to monitor
wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz
tar xvfz node_exporter-*linux-amd64.tar.gz
sudo cp node_exporter-*/node_exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/node_exporter

# Create systemd service
sudo tee /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Create user and start service
sudo useradd --no-create-home --shell /bin/false node_exporter
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter
```

**Install cAdvisor** on Docker hosts:
```bash
# Run cAdvisor container
docker run -d \
  --name=cadvisor \
  --restart=unless-stopped \
  --volume=/:/rootfs:ro \
  --volume=/var/run:/var/run:ro \
  --volume=/sys:/sys:ro \
  --volume=/var/lib/docker:/var/lib/docker:ro \
  --volume=/dev/disk/:/dev/disk:ro \
  --publish=8080:8080 \
  --detach=true \
  --privileged \
  --device=/dev/kmsg \
  gcr.io/cadvisor/cadvisor:latest
```

## Dashboard Import

### Recommended Community Dashboards

Import these dashboard IDs in Grafana:

1. **Node Exporter Full** (ID: 1860)
2. **Docker Container & Host Metrics** (ID: 179)
3. **Prometheus Stats** (ID: 2)
4. **Loki Logs** (ID: 13639)
5. **Blackbox Exporter** (ID: 7587)
6. **AlertManager** (ID: 9578)

**Import process:**
1. Grafana → + → Import
2. Enter dashboard ID
3. Select Prometheus datasource
4. Click Import

### Custom Dashboards

The repository includes pre-built dashboards in `grafana/dashboards/`:
- Infrastructure Overview
- Application Metrics
- Network Performance
- Security Monitoring
- Log Analysis

## Advanced Configuration

### SNMP Monitoring (UCG Ultra)

**Enable SNMP** on UCG Ultra:
1. Access UCG Ultra UI
2. Settings → Services → SNMP
3. Enable SNMP v2c or v3
4. Set community string or credentials

**Configure SNMP Exporter:**
```bash
# Generate SNMP configuration
docker run --rm -it \
  -v $PWD/snmp:/app \
  prom/snmp-generator:latest \
  generate
```

### Custom Metrics

**Add custom exporters** for specialized monitoring:
```yaml
# Example: Add to docker-compose.yml
  custom-exporter:
    image: custom/application-exporter:latest
    ports:
      - "9200:9200"
    environment:
      - TARGET_HOST=application.lab.local
```

### Log Parsing

**Configure custom log parsing** in `promtail/promtail.yml`:
```yaml
- job_name: custom-app
  static_configs:
    - targets:
        - localhost
      labels:
        job: custom-app
        __path__: /var/log/custom-app/*.log
  pipeline_stages:
    - regex:
        expression: '^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (?P<level>\w+) (?P<message>.*)$'
    - labels:
        level:
    - timestamp:
        source: timestamp
        format: '2006-01-02 15:04:05'
```

## Maintenance

### Daily Tasks
```bash
# Check service health
docker-compose ps

# Review alerts
curl -s http://localhost:9093/api/v1/alerts | jq

# Check disk usage
df -h
docker system df
```

### Weekly Tasks
```bash
# Update containers
docker-compose pull
docker-compose up -d

# Clean up logs
docker logs grafana 2>&1 | tail -100
docker logs prometheus 2>&1 | tail -100

# Backup configurations
tar -czf monitoring-backup-$(date +%Y%m%d).tar.gz \
  prometheus/prometheus.yml \
  alertmanager/alertmanager.yml \
  grafana/data/grafana.db
```

### Monthly Tasks
```bash
# Review metrics retention
# Check storage usage trends
# Update alert thresholds based on trends
# Test disaster recovery procedures
```

## Troubleshooting

### Common Issues

**Grafana won't start:**
```bash
# Check permissions
ls -la grafana/data/
sudo chown -R 472:472 grafana/data/

# Check logs
docker-compose logs grafana
```

**Prometheus can't scrape targets:**
```bash
# Test connectivity
curl http://target-host:9100/metrics

# Check Prometheus config
docker-compose exec prometheus promtool check config /etc/prometheus/prometheus.yml

# Check Prometheus logs
docker-compose logs prometheus
```

**No metrics from Node Exporter:**
```bash
# Check Node Exporter status
systemctl status node_exporter

# Test metrics endpoint
curl http://localhost:9100/metrics

# Check firewall
sudo ufw status
```

**AlertManager not sending emails:**
```bash
# Test SMTP configuration
docker-compose exec alertmanager /bin/amtool config show

# Check AlertManager logs
docker-compose logs alertmanager

# Test email manually
echo "test" | mail -s "test" your-email@domain.com
```

### Performance Optimization

**Prometheus optimization:**
```yaml
# In prometheus.yml
global:
  scrape_interval: 30s  # Increase if too much data
  evaluation_interval: 30s

# Reduce retention if storage is limited
command:
  - '--storage.tsdb.retention.time=30d'
  - '--storage.tsdb.retention.size=20GB'
```

**Loki optimization:**
```yaml
# In loki.yml
limits_config:
  ingestion_rate_mb: 4  # Reduce if overwhelming
  per_stream_rate_limit: 512KB
```

### Backup and Recovery

**Backup critical data:**
```bash
#!/bin/bash
# backup-monitoring.sh

BACKUP_DIR="/backup/monitoring/$(date +%Y%m%d)"
mkdir -p $BACKUP_DIR

# Backup Grafana database
docker-compose exec grafana grafana-cli admin export-dashboard > $BACKUP_DIR/grafana-export.json

# Backup Prometheus data
cp -r prometheus/data $BACKUP_DIR/prometheus-data

# Backup configurations
tar -czf $BACKUP_DIR/configs.tar.gz \
  prometheus/ \
  alertmanager/ \
  grafana/provisioning/ \
  blackbox/ \
  loki/ \
  promtail/

echo "Backup completed: $BACKUP_DIR"
```

**Recovery procedure:**
```bash
# Stop services
docker-compose down

# Restore data
cp -r backup/prometheus-data/* prometheus/data/
cp -r backup/grafana-data/* grafana/data/

# Restore configurations
tar -xzf backup/configs.tar.gz

# Start services
docker-compose up -d
```

## Security Considerations

### Access Control
- Change default Grafana password immediately
- Use strong passwords for all services
- Consider implementing reverse proxy with authentication
- Restrict network access to monitoring ports

### Data Protection
- Enable HTTPS for external access
- Encrypt sensitive data in configurations
- Regular security updates for all containers
- Monitor access logs for suspicious activity

### Alert Security
- Use app-specific passwords for email
- Avoid embedding secrets in configurations
- Consider using external secret management
- Regular review of alert channels and recipients

This monitoring stack provides comprehensive observability for your homelab infrastructure. Start with the basic setup and gradually add more advanced features as needed.
