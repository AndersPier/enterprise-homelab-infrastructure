#!/bin/bash
# AdGuard Home Setup Script for Enterprise Homelab
# Creates and configures AdGuard Home instances with high availability

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
        ADGUARD_PRIMARY_IP="${VLAN_ADGUARD_PRIMARY_IP}"
        ADGUARD_SECONDARY_IP="${VLAN_ADGUARD_SECONDARY_IP}"
        GATEWAY="${VLAN_ADGUARD_PRIMARY_IP%.*}.1"
        BRIDGE="vmbr20"
    else
        ADGUARD_PRIMARY_IP="${ADGUARD_PRIMARY_IP}"
        ADGUARD_SECONDARY_IP="${ADGUARD_SECONDARY_IP}"
        GATEWAY="${GATEWAY_IP}"
        BRIDGE="vmbr0"
    fi
}

# Create LXC container
create_adguard_container() {
    local container_id=$1
    local container_name=$2
    local ip_address=$3
    local description=$4
    
    log_info "Creating AdGuard container: $container_name ($ip_address)"
    
    # Check if container already exists
    if pct status $container_id &> /dev/null; then
        log_warning "Container $container_id already exists"
        return 0
    fi
    
    # Download Debian template if not available
    if ! pveam list local | grep -q "debian-12-standard"; then
        log_info "Downloading Debian 12 template..."
        pveam download local debian-12-standard_12.2-1_amd64.tar.zst
    fi
    
    # Create container
    pct create $container_id local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst \
        --hostname $container_name \
        --description "$description" \
        --memory 1024 \
        --cores 2 \
        --rootfs local-lvm:8 \
        --net0 name=eth0,bridge=$BRIDGE,ip=$ip_address/24,gw=$GATEWAY \
        --nameserver $ip_address \
        --searchdomain lab.local \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --protection 0 \
        --start 1
    
    # Wait for container to start
    log_info "Waiting for container to start..."
    sleep 30
    
    # Verify container is running
    if ! pct status $container_id | grep -q "running"; then
        log_error "Container $container_id failed to start"
        return 1
    fi
    
    log_success "Container $container_name created successfully"
}

# Configure basic container setup
configure_container_base() {
    local container_id=$1
    local container_name=$2
    
    log_info "Configuring base system for $container_name..."
    
    # Update system and install essential packages
    pct exec $container_id -- bash -c "
        export DEBIAN_FRONTEND=noninteractive
        
        # Update package lists
        apt update
        
        # Install essential packages
        apt install -y \
            curl \
            wget \
            vim \
            htop \
            net-tools \
            dnsutils \
            systemd-resolved \
            ca-certificates \
            gnupg \
            lsb-release \
            unzip \
            tar \
            logrotate
        
        # Set timezone
        ln -sf /usr/share/zoneinfo/${TIMEZONE:-UTC} /etc/localtime
        
        # Configure hostname
        echo '$container_name' > /etc/hostname
        echo '127.0.1.1 $container_name.lab.local $container_name' >> /etc/hosts
        
        # Create adguard user
        useradd -r -s /bin/false -d /var/lib/AdGuardHome -c 'AdGuard Home' adguard || true
        
        # Create directories
        mkdir -p /opt/AdGuardHome
        mkdir -p /var/lib/AdGuardHome
        mkdir -p /etc/AdGuardHome
        chown -R adguard:adguard /opt/AdGuardHome /var/lib/AdGuardHome /etc/AdGuardHome
    "
    
    log_success "Base configuration completed for $container_name"
}

# Install AdGuard Home
install_adguard_home() {
    local container_id=$1
    local container_name=$2
    local is_primary=${3:-true}
    
    log_info "Installing AdGuard Home on $container_name..."
    
    # Download and install AdGuard Home
    pct exec $container_id -- bash -c "
        # Download AdGuard Home
        cd /tmp
        curl -s -S -L -o AdGuardHome_linux_amd64.tar.gz \
            'https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_amd64.tar.gz'
        
        # Extract and install
        tar -xzf AdGuardHome_linux_amd64.tar.gz
        cp AdGuardHome/AdGuardHome /opt/AdGuardHome/
        chmod +x /opt/AdGuardHome/AdGuardHome
        chown adguard:adguard /opt/AdGuardHome/AdGuardHome
        
        # Clean up
        rm -rf AdGuardHome AdGuardHome_linux_amd64.tar.gz
    "
    
    # Create systemd service
    pct exec $container_id -- bash -c "
        cat > /etc/systemd/system/AdGuardHome.service << 'EOF'
[Unit]
Description=AdGuard Home: Network-level blocker
After=network.target
Wants=network.target

[Service]
Type=notify
User=adguard
Group=adguard
WorkingDirectory=/var/lib/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome --no-check-update --work-dir /var/lib/AdGuardHome --config /etc/AdGuardHome/AdGuardHome.yaml --pidfile /var/lib/AdGuardHome/AdGuardHome.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/AdGuardHome /etc/AdGuardHome
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF
    "
    
    # Enable and start service
    pct exec $container_id -- bash -c "
        systemctl daemon-reload
        systemctl enable AdGuardHome
    "
    
    log_success "AdGuard Home installed on $container_name"
}

# Configure AdGuard Home
configure_adguard_home() {
    local container_id=$1
    local container_name=$2
    local ip_address=$3
    local is_primary=${4:-true}
    
    log_info "Configuring AdGuard Home on $container_name..."
    
    # Generate configuration
    local server_name
    if [[ "$is_primary" == "true" ]]; then
        server_name="adguard-primary.lab.local"
    else
        server_name="adguard-secondary.lab.local"
    fi
    
    # Create AdGuard configuration
    pct exec $container_id -- bash -c "
        cat > /etc/AdGuardHome/AdGuardHome.yaml << 'EOF'
# AdGuard Home Configuration for $container_name
# Generated by Enterprise Homelab Infrastructure

http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:3000
  session_ttl: 720h

dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 30
  ratelimit_whitelist:
    - 192.168.0.0/16
    - 10.0.0.0/8
    - 172.16.0.0/12
  refuse_any: true
  
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - https://dns.quad9.net/dns-query
    - tls://1.1.1.1
    - tls://8.8.8.8
    - tls://9.9.9.9
  
  upstream_dns_file: \"\"
  
  bootstrap_dns:
    - 1.1.1.1:53
    - 8.8.8.8:53
    - 9.9.9.9:53
    - 208.67.222.222:53
    
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  
  allowed_clients: []
  disallowed_clients: []
  
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
    
  cache_size: 8388608
  cache_ttl_min: 0
  cache_ttl_max: 86400
  cache_optimistic: true
  
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: true
  
  edns_client_subnet:
    custom_ip: \"\"
    enabled: false
    use_custom: false
    
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: \"\"
  
  filtering_enabled: true
  filters_update_interval: 12
  parental_enabled: false
  safebrowsing_enabled: true
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
    
  rewrites:
    - domain: \"proxmox.lab.local\"
      answer: \"${PROXMOX_IP:-192.168.1.10}\"
    - domain: \"qnap.lab.local\"  
      answer: \"${QNAP_IP:-192.168.1.60}\"
    - domain: \"adguard.lab.local\"
      answer: \"$ip_address\"
    - domain: \"adguard-primary.lab.local\"
      answer: \"$ADGUARD_PRIMARY_IP\"
    - domain: \"adguard-secondary.lab.local\"
      answer: \"$ADGUARD_SECONDARY_IP\"
    - domain: \"monitoring.lab.local\"
      answer: \"${MONITORING_IP:-192.168.1.26}\"
    - domain: \"dokploy-dev.lab.local\"
      answer: \"${DOKPLOY_DEV_IP:-192.168.1.30}\"
    - domain: \"dokploy-staging.lab.local\"
      answer: \"${DOKPLOY_STAGING_IP:-192.168.1.40}\"
    - domain: \"dokploy-prod.lab.local\"
      answer: \"${DOKPLOY_PROD_IP:-192.168.1.50}\"
    - domain: \"gateway.lab.local\"
      answer: \"${GATEWAY_IP:-192.168.1.1}\"
      
  blocked_services: []
    
  upstream_timeout: 10s
  private_networks:
    - 192.168.0.0/16
    - 172.16.0.0/12
    - 10.0.0.0/8
    - fc00::/7
    - fe80::/10
    - ::1/128
    
  use_private_ptr_resolvers: true
  local_ptr_upstreams:
    - ${GATEWAY_IP:-192.168.1.1}
    
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: true

tls:
  enabled: false
  server_name: \"$server_name\"
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 784
  port_dnscrypt: 0
  dnscrypt_config_file: \"\"
  allow_unencrypted_doh: true
  certificate_chain: \"\"
  private_key: \"\"
  certificate_path: \"\"
  private_key_path: \"\"
  strict_sni_check: false

querylog:
  enabled: true
  file_enabled: true
  interval: 2160h
  size_memory: 1000
  ignored:
    - '|.^'

statistics:
  enabled: true
  interval: 2160h
  ignored:
    - '|.^'

filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
    
  - enabled: true
    url: https://someonewhocares.org/hosts/zero/hosts
    name: Dan Pollock's List
    id: 2
    
  - enabled: true
    url: https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/combined_disguised_trackers_justdomains.txt
    name: AdGuard CNAME-cloaked trackers list
    id: 3
    
  - enabled: true
    url: https://www.github.developerdan.com/hosts/lists/ads-and-tracking-extended.txt
    name: Developer Dan's Ads & Tracking Extended
    id: 4
    
  - enabled: true
    url: https://malware-filter.gitlab.io/malware-filter/urlhaus-filter-agh.txt
    name: Malware Domain List
    id: 5
    
  - enabled: true
    url: https://raw.githubusercontent.com/DandelionSprout/adfilt/master/Alternate%20versions%20Anti-Malware%20List/AntiMalwareAdGuardHome.txt
    name: Anti-Malware List
    id: 6
    
  - enabled: true
    url: https://phishing.army/download/phishing_army_blocklist_extended.txt
    name: Phishing Army Extended
    id: 7
    
  - enabled: true
    url: https://raw.githubusercontent.com/crazy-max/WindowsSpyBlocker/master/data/hosts/spy.txt
    name: Windows Spy Blocker
    id: 8

whitelist_filters:
  - enabled: true
    url: https://raw.githubusercontent.com/AdguardTeam/AdguardFilters/master/BaseFilter/sections/allowlist.txt
    name: AdGuard Allowlist
    id: 1000

user_rules:
  - '@@||lab.local^$important'
  - '@@||dokploy.lab.local^$important'
  - '@@||proxmox.lab.local^$important'
  - '@@||qnap.lab.local^$important'
  - '@@||adguard.lab.local^$important'
  - '@@||monitoring.lab.local^$important'
  - '@@||gateway.lab.local^$important'
  - '@@||docker.io^$important'
  - '@@||registry-1.docker.io^$important'
  - '@@||ghcr.io^$important'
  - '@@||quay.io^$important'
  - '@@||github.com^$important'
  - '@@||githubusercontent.com^$important'
  - '@@||npmjs.org^$important'
  - '@@||cloudflare.com^$important'
  - '@@||letsencrypt.org^$important'

dhcp:
  enabled: false
  interface_name: \"\"
  local_domain_name: lab.local

clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: false
    hosts: true
  persistent: []

log:
  file: \"\"
  max_backups: 3
  max_size: 100
  max_age: 7
  compress: true
  local_time: true
  verbose: false

os:
  group: \"\"
  user: \"\"
  rlimit_nofile: 0

schema_version: 20
EOF
        
        # Set ownership
        chown adguard:adguard /etc/AdGuardHome/AdGuardHome.yaml
    "
    
    log_success "AdGuard Home configured on $container_name"
}

# Start AdGuard Home service
start_adguard_service() {
    local container_id=$1
    local container_name=$2
    
    log_info "Starting AdGuard Home service on $container_name..."
    
    pct exec $container_id -- bash -c "
        # Start the service
        systemctl start AdGuardHome
        
        # Wait for service to be ready
        sleep 10
        
        # Check if service is running
        if systemctl is-active --quiet AdGuardHome; then
            echo 'AdGuard Home service started successfully'
        else
            echo 'Failed to start AdGuard Home service'
            systemctl status AdGuardHome
            exit 1
        fi
    "
    
    log_success "AdGuard Home service started on $container_name"
}

# Configure log rotation
setup_log_rotation() {
    local container_id=$1
    local container_name=$2
    
    log_info "Setting up log rotation for $container_name..."
    
    pct exec $container_id -- bash -c "
        cat > /etc/logrotate.d/adguard << 'EOF'
/var/lib/AdGuardHome/data/querylog.json {
    daily
    missingok
    rotate 7
    compress
    notifempty
    copytruncate
    postrotate
        systemctl reload AdGuardHome > /dev/null 2>&1 || true
    endscript
}
EOF
    "
    
    log_success "Log rotation configured for $container_name"
}

# Validate AdGuard installation
validate_adguard() {
    local container_id=$1
    local container_name=$2
    local ip_address=$3
    
    log_info "Validating AdGuard installation on $container_name..."
    
    # Test DNS resolution
    if ! nslookup google.com "$ip_address" &> /dev/null; then
        log_error "DNS resolution test failed on $ip_address"
        return 1
    fi
    
    # Test web interface
    if ! curl -f "http://$ip_address:3000" &> /dev/null; then
        log_error "Web interface not accessible on $ip_address:3000"
        return 1
    fi
    
    # Check service status
    if ! pct exec $container_id -- systemctl is-active --quiet AdGuardHome; then
        log_error "AdGuard Home service not running on $container_name"
        return 1
    fi
    
    log_success "AdGuard validation passed for $container_name"
}

# Generate setup summary
generate_summary() {
    log_info "=== AdGuard Home Setup Summary ==="
    echo ""
    echo "Primary AdGuard Instance:"
    echo "  - Container ID: 100"
    echo "  - IP Address: $ADGUARD_PRIMARY_IP"
    echo "  - Web Interface: http://$ADGUARD_PRIMARY_IP:3000"
    echo "  - DNS Server: $ADGUARD_PRIMARY_IP:53"
    echo ""
    echo "Secondary AdGuard Instance:"
    echo "  - Container ID: 101"
    echo "  - IP Address: $ADGUARD_SECONDARY_IP"
    echo "  - Web Interface: http://$ADGUARD_SECONDARY_IP:3000"
    echo "  - DNS Server: $ADGUARD_SECONDARY_IP:53"
    echo ""
    echo "Configuration Steps:"
    echo "1. Access web interfaces to complete initial setup"
    echo "2. Configure UCG Ultra to use these DNS servers"
    echo "3. Test DNS resolution from client devices"
    echo "4. Review filter lists and customize as needed"
    echo ""
    echo "High Availability:"
    echo "- Configure primary DNS: $ADGUARD_PRIMARY_IP"
    echo "- Configure secondary DNS: $ADGUARD_SECONDARY_IP"
    echo "- Automatic failover will occur if primary fails"
    echo ""
    echo "Initial Credentials:"
    echo "- Username: admin"
    echo "- Password: Set during first web interface access"
    echo ""
}

# Main setup function
main() {
    echo "=================================================================="
    echo "  AdGuard Home Setup for Enterprise Homelab"
    echo "=================================================================="
    echo ""
    
    # Load configuration
    load_config
    
    # Validate prerequisites
    if ! command -v pct &> /dev/null; then
        log_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    
    log_info "Setting up AdGuard Home instances..."
    log_info "Primary IP: $ADGUARD_PRIMARY_IP"
    log_info "Secondary IP: $ADGUARD_SECONDARY_IP"
    log_info "Network Mode: $NETWORK_MODE"
    echo ""
    
    # Setup primary AdGuard instance
    log_info "=== Setting up Primary AdGuard Instance ==="
    create_adguard_container 100 "adguard-primary" "$ADGUARD_PRIMARY_IP" "Primary AdGuard Home DNS server"
    configure_container_base 100 "adguard-primary"
    install_adguard_home 100 "adguard-primary" true
    configure_adguard_home 100 "adguard-primary" "$ADGUARD_PRIMARY_IP" true
    setup_log_rotation 100 "adguard-primary"
    start_adguard_service 100 "adguard-primary"
    validate_adguard 100 "adguard-primary" "$ADGUARD_PRIMARY_IP"
    
    echo ""
    
    # Setup secondary AdGuard instance
    log_info "=== Setting up Secondary AdGuard Instance ==="
    create_adguard_container 101 "adguard-secondary" "$ADGUARD_SECONDARY_IP" "Secondary AdGuard Home DNS server"
    configure_container_base 101 "adguard-secondary"
    install_adguard_home 101 "adguard-secondary" false
    configure_adguard_home 101 "adguard-secondary" "$ADGUARD_SECONDARY_IP" false
    setup_log_rotation 101 "adguard-secondary"
    start_adguard_service 101 "adguard-secondary"
    validate_adguard 101 "adguard-secondary" "$ADGUARD_SECONDARY_IP"
    
    echo ""
    log_success "AdGuard Home setup completed successfully!"
    echo ""
    
    generate_summary
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
