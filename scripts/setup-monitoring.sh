#!/bin/bash
# Monitoring Stack Setup Script for Enterprise Homelab
# Deploys comprehensive monitoring with Prometheus, Grafana, and AlertManager

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
        MONITORING_IP="${VLAN_MONITORING_IP}"
        BRIDGE="vmbr20"
        GATEWAY="${VLAN_MONITORING_IP%.*}.1"
    else
        MONITORING_IP="${MONITORING_IP}"
        BRIDGE="vmbr0"
        GATEWAY="${GATEWAY_IP}"
    fi
}

# Create monitoring container
create_monitoring_container() {
    log_progress "Creating monitoring LXC container..."
    
    local container_id=110
    local container_name="monitoring"
    local ip_address="$MONITORING_IP"
    
    # Check if container already exists
    if pct status $container_id &> /dev/null; then
        log_warning "Container $container_id already exists"
        return 0
    fi
    
    # Download Ubuntu template if not available
    if ! pveam list local | grep -q "ubuntu-22.04-standard"; then
        log_info "Downloading Ubuntu 22.04 template..."
        pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
    fi
    
    # Create container
    pct create $container_id local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
        --hostname $container_name \
        --description "Monitoring stack with Prometheus, Grafana, and AlertManager" \
        --memory 4096 \
        --cores 4 \
        --rootfs local-lvm:20 \
        --net0 name=eth0,bridge=$BRIDGE,ip=$ip_address/24,gw=$GATEWAY \
        --nameserver "${ADGUARD_PRIMARY_IP:-192.168.1.20}" \
        --searchdomain lab.local \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --protection 0 \
        --start 1
    
    # Wait for container to start
    log_info "Waiting for container to start..."
    sleep 30
    
    log_success "Monitoring container created successfully"
}

# Configure container base system
configure_container_base() {
    local container_id=110
    
    log_progress "Configuring base system..."
    
    # Update system and install essential packages
    pct exec $container_id -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        
        # Update package lists
        apt update
        apt upgrade -y
        
        # Install essential packages
        apt install -y \
            curl \
            wget \
            vim \
            htop \
            net-tools \
            dnsutils \
            ca-certificates \
            gnupg \
            lsb-release \
            unzip \
            tar \
            git \
            jq \
            python3 \
            python3-pip \
            systemd-resolved
        
        # Set timezone
        ln -sf /usr/share/zoneinfo/${TIMEZONE:-UTC} /etc/localtime
        
        # Configure hostname
        echo 'monitoring' > /etc/hostname
        echo '127.0.1.1 monitoring.lab.local monitoring' >> /etc/hosts
        
        # Create directories
        mkdir -p /opt/monitoring
        mkdir -p /var/log/monitoring
    "
    
    log_success "Base system configured"
}

# Install Docker
install_docker() {
    local container_id=110
    
    log_progress "Installing Docker..."
    
    pct exec $container_id -- bash -c "
        # Install Docker
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        
        # Install Docker Compose
        curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        
        # Enable and start Docker
        systemctl enable docker
        systemctl start docker
        
        # Configure Docker daemon
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << 'DAEMON_EOF'
{
  \"log-driver\": \"json-file\",
  \"log-opts\": {
    \"max-size\": \"10m\",
    \"max-file\": \"3\"
  },
  \"storage-driver\": \"overlay2\",
  \"dns\": [\"${ADGUARD_PRIMARY_IP:-192.168.1.20}\", \"${ADGUARD_SECONDARY_IP:-192.168.1.21}\"]
}
DAEMON_EOF
        
        # Restart Docker to apply configuration
        systemctl restart docker
        
        # Create Docker networks
        docker network create monitoring-net || true
    "
    
    log_success "Docker installed and configured"
}

# Create monitoring configuration
create_monitoring_config() {
    local container_id=110
    
    log_progress "Creating monitoring configuration..."
    
    # Create docker-compose.yml
    pct exec $container_id -- bash -c "
        mkdir -p /opt/monitoring/{prometheus,grafana,alertmanager,loki,promtail}
        
        cat > /opt/monitoring/docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # Prometheus - Metrics Collection
  prometheus:
    image: prom/prometheus:v2.48.0
    container_name: prometheus
    ports:
      - \"9090:9090\"
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-90d}'
      - '--storage.tsdb.retention.size=50GB'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
      - '--web.external-url=http://monitoring.lab.local:9090'
    restart: unless-stopped
    networks:
      - monitoring-net

  # Grafana - Visualization
  grafana:
    image: grafana/grafana:10.2.2
    container_name: grafana
    ports:
      - \"3000:3000\"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-homelab123}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_USERS_DEFAULT_THEME=dark
      - GF_FEATURE_TOGGLES_ENABLE=publicDashboards
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
      - GF_SERVER_ROOT_URL=http://monitoring.lab.local:3000
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/etc/grafana/provisioning/dashboards/homelab-overview.json
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    restart: unless-stopped
    networks:
      - monitoring-net
    depends_on:
      - prometheus

  # AlertManager - Alert Routing
  alertmanager:
    image: prom/alertmanager:v0.26.0
    container_name: alertmanager
    ports:
      - \"9093:9093\"
    volumes:
      - ./alertmanager:/etc/alertmanager
      - alertmanager-data:/alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
      - '--web.external-url=http://monitoring.lab.local:9093'
      - '--cluster.listen-address=0.0.0.0:9094'
    restart: unless-stopped
    networks:
      - monitoring-net

  # Node Exporter - System Metrics
  node-exporter:
    image: prom/node-exporter:v1.7.0
    container_name: node-exporter
    ports:
      - \"9100:9100\"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$|/)'
      - '--collector.systemd'
    restart: unless-stopped
    networks:
      - monitoring-net
    privileged: true

  # cAdvisor - Container Metrics
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.2
    container_name: cadvisor
    ports:
      - \"8080:8080\"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /dev/disk:/dev/disk:ro
    devices:
      - /dev/kmsg
    restart: unless-stopped
    networks:
      - monitoring-net
    privileged: true

  # Blackbox Exporter - Endpoint Monitoring
  blackbox-exporter:
    image: prom/blackbox-exporter:v0.24.0
    container_name: blackbox-exporter
    ports:
      - \"9115:9115\"
    volumes:
      - ./blackbox:/etc/blackbox_exporter
    command:
      - '--config.file=/etc/blackbox_exporter/blackbox.yml'
    restart: unless-stopped
    networks:
      - monitoring-net

  # Loki - Log Aggregation
  loki:
    image: grafana/loki:2.9.2
    container_name: loki
    ports:
      - \"3100:3100\"
    volumes:
      - ./loki:/etc/loki
      - loki-data:/loki
    command:
      - '-config.file=/etc/loki/loki.yml'
    restart: unless-stopped
    networks:
      - monitoring-net

  # Promtail - Log Collection
  promtail:
    image: grafana/promtail:2.9.2
    container_name: promtail
    volumes:
      - ./promtail:/etc/promtail
      - /var/log:/var/log:ro
    command:
      - '-config.file=/etc/promtail/promtail.yml'
    restart: unless-stopped
    networks:
      - monitoring-net
    depends_on:
      - loki

  # Uptime Kuma - Service Uptime Monitoring
  uptime-kuma:
    image: louislam/uptime-kuma:1.23.11
    container_name: uptime-kuma
    ports:
      - \"3001:3001\"
    volumes:
      - uptime-kuma-data:/app/data
    restart: unless-stopped
    networks:
      - monitoring-net

volumes:
  prometheus-data:
    driver: local
  grafana-data:
    driver: local
  alertmanager-data:
    driver: local
  loki-data:
    driver: local
  uptime-kuma-data:
    driver: local

networks:
  monitoring-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
COMPOSE_EOF
    "
    
    log_success "Docker Compose configuration created"
}

# Create Prometheus configuration
create_prometheus_config() {
    local container_id=110
    
    log_progress "Creating Prometheus configuration..."
    
    pct exec $container_id -- bash -c "
        mkdir -p /opt/monitoring/prometheus/rules
        
        # Main Prometheus configuration
        cat > /opt/monitoring/prometheus/prometheus.yml << 'PROM_EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: 'homelab'
    replica: 'prometheus-01'

rule_files:
  - \"rules/*.yml\"

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

scrape_configs:
  # Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
    scrape_interval: 15s

  # Node Exporters
  - job_name: 'node-exporter'
    static_configs:
      - targets:
        - 'localhost:9100'  # Monitoring host
        - '${PROXMOX_IP:-192.168.1.10}:9100'  # Proxmox host
        - '${ADGUARD_PRIMARY_IP:-192.168.1.20}:9100'  # AdGuard primary
        - '${ADGUARD_SECONDARY_IP:-192.168.1.21}:9100'  # AdGuard secondary
        - '${DOKPLOY_DEV_IP:-192.168.1.30}:9100'  # Dokploy dev
        - '${DOKPLOY_STAGING_IP:-192.168.1.40}:9100'  # Dokploy staging
        - '${DOKPLOY_PROD_IP:-192.168.1.50}:9100'  # Dokploy prod
    scrape_interval: 15s

  # Container Metrics
  - job_name: 'cadvisor'
    static_configs:
      - targets:
        - 'localhost:8080'
        - '${DOKPLOY_DEV_IP:-192.168.1.30}:8080'
        - '${DOKPLOY_STAGING_IP:-192.168.1.40}:8080'
        - '${DOKPLOY_PROD_IP:-192.168.1.50}:8080'
    scrape_interval: 15s

  # Blackbox - HTTP/HTTPS Endpoints
  - job_name: 'blackbox-http'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://dokploy-dev.lab.local:3000
        - http://dokploy-staging.lab.local:3000
        - http://dokploy-prod.lab.local:3000
        - http://adguard-primary.lab.local:3000
        - http://adguard-secondary.lab.local:3000
        - http://monitoring.lab.local:3000
        - https://qnap.lab.local
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115

  # Blackbox - DNS Checks
  - job_name: 'blackbox-dns'
    metrics_path: /probe
    params:
      module: [dns_udp]
    static_configs:
      - targets:
        - ${ADGUARD_PRIMARY_IP:-192.168.1.20}:53
        - ${ADGUARD_SECONDARY_IP:-192.168.1.21}:53
        - 1.1.1.1:53
        - 8.8.8.8:53
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
PROM_EOF
        
        # Alert rules
        cat > /opt/monitoring/prometheus/rules/homelab-alerts.yml << 'ALERTS_EOF'
groups:
  - name: infrastructure.rules
    rules:
      # Host down
      - alert: HostDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
          category: infrastructure
        annotations:
          summary: \"Host {{ \$labels.instance }} is down\"
          description: \"{{ \$labels.instance }} has been down for more than 1 minute\"

      # High CPU usage
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > ${CPU_WARNING_THRESHOLD:-80}
        for: 5m
        labels:
          severity: warning
          category: infrastructure
        annotations:
          summary: \"High CPU usage on {{ \$labels.instance }}\"
          description: \"CPU usage is above ${CPU_WARNING_THRESHOLD:-80}% for more than 5 minutes\"

      # Critical CPU usage
      - alert: CriticalCPUUsage
        expr: 100 - (avg by(instance) (irate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > ${CPU_CRITICAL_THRESHOLD:-90}
        for: 2m
        labels:
          severity: critical
          category: infrastructure
        annotations:
          summary: \"Critical CPU usage on {{ \$labels.instance }}\"
          description: \"CPU usage is above ${CPU_CRITICAL_THRESHOLD:-90}% for more than 2 minutes\"

      # High memory usage
      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > ${MEMORY_WARNING_THRESHOLD:-85}
        for: 5m
        labels:
          severity: warning
          category: infrastructure
        annotations:
          summary: \"High memory usage on {{ \$labels.instance }}\"
          description: \"Memory usage is above ${MEMORY_WARNING_THRESHOLD:-85}% for more than 5 minutes\"

      # Critical memory usage
      - alert: CriticalMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > ${MEMORY_CRITICAL_THRESHOLD:-95}
        for: 1m
        labels:
          severity: critical
          category: infrastructure
        annotations:
          summary: \"Critical memory usage on {{ \$labels.instance }}\"
          description: \"Memory usage is above ${MEMORY_CRITICAL_THRESHOLD:-95}% for more than 1 minute\"

      # High disk usage
      - alert: HighDiskUsage
        expr: 100 - ((node_filesystem_avail_bytes * 100) / node_filesystem_size_bytes) > ${DISK_WARNING_THRESHOLD:-80}
        for: 5m
        labels:
          severity: warning
          category: infrastructure
        annotations:
          summary: \"High disk usage on {{ \$labels.instance }}\"
          description: \"Disk usage is above ${DISK_WARNING_THRESHOLD:-80}% on {{ \$labels.mountpoint }}\"

      # Critical disk usage
      - alert: CriticalDiskUsage
        expr: 100 - ((node_filesystem_avail_bytes * 100) / node_filesystem_size_bytes) > ${DISK_CRITICAL_THRESHOLD:-90}
        for: 1m
        labels:
          severity: critical
          category: infrastructure
        annotations:
          summary: \"Critical disk usage on {{ \$labels.instance }}\"
          description: \"Disk usage is above ${DISK_CRITICAL_THRESHOLD:-90}% on {{ \$labels.mountpoint }} - immediate action required\"

  - name: network.rules
    rules:
      # DNS resolution failure
      - alert: DNSResolutionFailure
        expr: probe_success{job=\"blackbox-dns\"} == 0
        for: 2m
        labels:
          severity: critical
          category: network
        annotations:
          summary: \"DNS resolution failed for {{ \$labels.instance }}\"
          description: \"DNS server {{ \$labels.instance }} is not responding\"

      # HTTP endpoint down
      - alert: HTTPEndpointDown
        expr: probe_success{job=\"blackbox-http\"} == 0
        for: 2m
        labels:
          severity: warning
          category: network
        annotations:
          summary: \"HTTP endpoint {{ \$labels.instance }} is down\"
          description: \"HTTP probe failed for {{ \$labels.instance }}\"
ALERTS_EOF
    "
    
    log_success "Prometheus configuration created"
}

# Create AlertManager configuration
create_alertmanager_config() {
    local container_id=110
    
    log_progress "Creating AlertManager configuration..."
    
    pct exec $container_id -- bash -c "
        cat > /opt/monitoring/alertmanager/alertmanager.yml << 'ALERT_EOF'
global:
  smtp_smarthost: '${SMTP_SERVER:-smtp.gmail.com:587}'
  smtp_from: '${ALERT_EMAIL:-homelab-alerts@${DOMAIN_NAME}}'
  smtp_auth_username: '${SMTP_USERNAME:-alerts@${DOMAIN_NAME}}'
  smtp_auth_password: '${SMTP_PASSWORD:-your-app-password}'

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'
  routes:
    # Critical alerts - immediate notification
    - match:
        severity: critical
      receiver: 'critical-alerts'
      group_wait: 0s
      repeat_interval: 5m

    # Infrastructure alerts
    - match:
        category: infrastructure
      receiver: 'infrastructure-team'

    # Network alerts
    - match:
        category: network
      receiver: 'network-team'

receivers:
  - name: 'default'
    email_configs:
      - to: '${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}'
        subject: 'Homelab Alert: {{ .GroupLabels.alertname }}'
        body: |
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          Labels: {{ range .Labels.SortedPairs }}{{ .Name }}: {{ .Value }}{{ end }}
          {{ end }}

  - name: 'critical-alerts'
    email_configs:
      - to: '${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}'
        subject: 'CRITICAL: Homelab Alert - {{ .GroupLabels.alertname }}'
        body: |
          🚨 CRITICAL ALERT 🚨
          
          {{ range .Alerts }}
          Alert: {{ .Annotations.summary }}
          Description: {{ .Annotations.description }}
          Severity: {{ .Labels.severity }}
          Instance: {{ .Labels.instance }}
          Time: {{ .StartsAt }}
          {{ end }}

  - name: 'infrastructure-team'
    email_configs:
      - to: '${TEAM_EMAIL:-team@${DOMAIN_NAME}}'
        subject: 'Infrastructure Alert: {{ .GroupLabels.alertname }}'

  - name: 'network-team'
    email_configs:
      - to: '${TEAM_EMAIL:-team@${DOMAIN_NAME}}'
        subject: 'Network Alert: {{ .GroupLabels.alertname }}'

inhibit_rules:
  # Inhibit any warning-level alert if the same alert is already critical
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
ALERT_EOF
    "
    
    log_success "AlertManager configuration created"
}

# Create Blackbox Exporter configuration
create_blackbox_config() {
    local container_id=110
    
    log_progress "Creating Blackbox Exporter configuration..."
    
    pct exec $container_id -- bash -c "
        cat > /opt/monitoring/blackbox/blackbox.yml << 'BLACKBOX_EOF'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: [\"HTTP/1.1\", \"HTTP/2.0\"]
      valid_status_codes: []
      method: GET
      headers:
        Host: vhost.example.com
        Accept-Language: en-US
      no_follow_redirects: false
      fail_if_ssl: false
      fail_if_not_ssl: false
      tls_config:
        insecure_skip_verify: false
      preferred_ip_protocol: \"ip4\"

  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      query_name: \"google.com\"
      query_type: \"A\"
      valid_rcodes:
      - NOERROR
      validate_answer_rrs:
        fail_if_matches_regexp:
        - \".*127.0.0.1\"
        fail_if_not_matches_regexp:
        - \"www.google.com.\t300\tIN\tA\t.*\"
      validate_authority_rrs:
        fail_if_matches_regexp:
        - \".*127.0.0.1\"
      validate_additional_rrs:
        fail_if_matches_regexp:
        - \".*127.0.0.1\"
      preferred_ip_protocol: \"ip4\"
BLACKBOX_EOF
    "
    
    log_success "Blackbox Exporter configuration created"
}

# Create Grafana provisioning
create_grafana_config() {
    local container_id=110
    
    log_progress "Creating Grafana configuration..."
    
    pct exec $container_id -- bash -c "
        mkdir -p /opt/monitoring/grafana/provisioning/{datasources,dashboards}
        
        # Datasource configuration
        cat > /opt/monitoring/grafana/provisioning/datasources/prometheus.yml << 'DATASOURCE_EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true

  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: true
DATASOURCE_EOF

        # Dashboard provisioning
        cat > /opt/monitoring/grafana/provisioning/dashboards/default.yml << 'DASHBOARD_EOF'
apiVersion: 1

providers:
  - name: 'homelab'
    orgId: 1
    folder: 'Homelab'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
DASHBOARD_EOF
    "
    
    log_success "Grafana configuration created"
}

# Deploy monitoring stack
deploy_monitoring_stack() {
    local container_id=110
    
    log_progress "Deploying monitoring stack..."
    
    pct exec $container_id -- bash -c "
        cd /opt/monitoring
        
        # Start the monitoring stack
        docker-compose up -d
        
        # Wait for services to start
        echo 'Waiting for services to initialize...'
        sleep 30
        
        # Check if services are running
        docker-compose ps
    "
    
    log_success "Monitoring stack deployed"
}

# Validate monitoring deployment
validate_monitoring() {
    local container_id=110
    
    log_progress "Validating monitoring deployment..."
    
    # Check if services are accessible
    local services=(
        "prometheus:9090"
        "grafana:3000"
        "alertmanager:9093"
        "uptime-kuma:3001"
    )
    
    for service in "${services[@]}"; do
        local service_name="${service%:*}"
        local port="${service#*:}"
        
        if ! curl -f -s "http://$MONITORING_IP:$port" > /dev/null; then
            log_error "$service_name not accessible on port $port"
            return 1
        fi
        
        log_success "$service_name is accessible"
    done
    
    log_success "Monitoring validation completed"
}

# Install Node Exporter on other hosts
install_node_exporters() {
    log_progress "Installing Node Exporters on other hosts..."
    
    # List of hosts to install node exporter on
    local hosts=(
        "${DOKPLOY_DEV_IP:-192.168.1.30}"
        "${DOKPLOY_STAGING_IP:-192.168.1.40}"
        "${DOKPLOY_PROD_IP:-192.168.1.50}"
    )
    
    for host in "${hosts[@]}"; do
        log_info "Installing Node Exporter on $host..."
        
        # Create installation script
        cat > /tmp/install-node-exporter.sh << 'NODE_EOF'
#!/bin/bash
set -e

# Download and install Node Exporter
cd /tmp
wget -q https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-1.7.0.linux-amd64.tar.gz
tar -xzf node_exporter-1.7.0.linux-amd64.tar.gz
sudo cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/node_exporter

# Create user
sudo useradd --no-create-home --shell /bin/false node_exporter || true

# Create systemd service
sudo tee /etc/systemd/system/node_exporter.service > /dev/null << 'SERVICE_EOF'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.systemd.unit-whitelist=(docker|ssh|dokploy).service

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Enable and start service
sudo systemctl daemon-reload
sudo systemctl enable node_exporter
sudo systemctl start node_exporter

# Clean up
rm -rf /tmp/node_exporter-*

echo "Node Exporter installed successfully"
NODE_EOF
        
        # Copy and execute on remote host
        if nc -z "$host" 22 2>/dev/null; then
            scp -o StrictHostKeyChecking=no /tmp/install-node-exporter.sh ubuntu@"$host":/tmp/
            ssh -o StrictHostKeyChecking=no ubuntu@"$host" "chmod +x /tmp/install-node-exporter.sh && /tmp/install-node-exporter.sh"
            log_success "Node Exporter installed on $host"
        else
            log_warning "Cannot connect to $host, skipping Node Exporter installation"
        fi
    done
    
    # Clean up
    rm -f /tmp/install-node-exporter.sh
    
    log_success "Node Exporter installation completed"
}

# Generate monitoring summary
generate_summary() {
    log_info "=== Monitoring Stack Summary ==="
    echo ""
    echo "Monitoring Host: $MONITORING_IP"
    echo ""
    echo "Services:"
    echo "  - Prometheus: http://$MONITORING_IP:9090"
    echo "  - Grafana: http://$MONITORING_IP:3000"
    echo "  - AlertManager: http://$MONITORING_IP:9093"
    echo "  - Uptime Kuma: http://$MONITORING_IP:3001"
    echo ""
    echo "Credentials:"
    echo "  - Grafana: admin / ${GRAFANA_ADMIN_PASSWORD:-homelab123}"
    echo ""
    echo "Configuration:"
    echo "  - Data retention: ${PROMETHEUS_RETENTION:-90d}"
    echo "  - Alert thresholds: CPU ${CPU_WARNING_THRESHOLD:-80}%/${CPU_CRITICAL_THRESHOLD:-90}%, Memory ${MEMORY_WARNING_THRESHOLD:-85}%/${MEMORY_CRITICAL_THRESHOLD:-95}%"
    echo "  - Email alerts: ${ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"
    echo ""
    echo "Next Steps:"
    echo "1. Access Grafana and configure additional dashboards"
    echo "2. Set up custom alert rules in AlertManager"
    echo "3. Configure Uptime Kuma for service monitoring"
    echo "4. Test alert notifications"
    echo "5. Import additional Grafana dashboards from grafana.com"
    echo ""
}

# Main monitoring setup function
main() {
    echo "=================================================================="
    echo "  Monitoring Stack Setup for Enterprise Homelab"
    echo "=================================================================="
    echo ""
    
    # Load configuration
    load_config
    
    log_info "Setting up comprehensive monitoring stack..."
    log_info "Monitoring IP: $MONITORING_IP"
    log_info "Network Mode: $NETWORK_MODE"
    echo ""
    
    # Deploy monitoring infrastructure
    create_monitoring_container
    configure_container_base
    install_docker
    create_monitoring_config
    create_prometheus_config
    create_alertmanager_config
    create_blackbox_config
    create_grafana_config
    deploy_monitoring_stack
    validate_monitoring
    install_node_exporters
    
    echo ""
    log_success "Monitoring stack setup completed successfully!"
    echo ""
    
    generate_summary
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
