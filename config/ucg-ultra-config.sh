#!/bin/bash
# UCG Ultra Configuration Script for Enterprise Homelab
# This script generates the configuration commands for the Ubiquiti Cloud Gateway Ultra
# Version: 2.0 - Updated for modern UCG Ultra firmware

set -euo pipefail

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

# Configuration variables - modify these for your setup
DOMAIN_NAME="yourdomain.com"
INFRASTRUCTURE_IP="192.168.1.25"
DOKPLOY_DEV_IP="192.168.1.30"
DOKPLOY_STAGING_IP="192.168.1.40"
DOKPLOY_PROD_IP="192.168.1.50"
PROXMOX_IP="192.168.1.10"
QNAP_IP="192.168.1.60"
ADGUARD_PRIMARY_IP="192.168.1.20"
ADGUARD_SECONDARY_IP="192.168.1.21"
MONITORING_IP="192.168.1.26"
VPN_NETWORK="10.10.10.0/24"

print_header() {
    echo "=================================================================="
    echo "    UCG Ultra Configuration for Enterprise Homelab"
    echo "=================================================================="
    echo ""
    echo "This script provides configuration steps for your UCG Ultra."
    echo "Apply these settings in the UniFi Network Controller web interface."
    echo ""
    echo "Prerequisites:"
    echo "- UCG Ultra updated to latest firmware"
    echo "- UniFi Network Controller accessible"
    echo "- Static IP assignments configured"
    echo ""
    echo "Network Mode: Single Network (192.168.1.0/24)"
    echo "For VLAN setup, see network/vlan-setup.md"
    echo ""
}

configure_basic_settings() {
    log_info "=== Basic Network Configuration ==="
    cat << 'EOF'

1. WAN Configuration:
   - Navigate to: Settings → Internet
   - Connection Type: DHCP (or Static if ISP requires)
   - DNS Servers: 
     * Primary: 192.168.1.20 (AdGuard Primary)
     * Secondary: 192.168.1.21 (AdGuard Secondary)
     * Fallback: 1.1.1.1, 8.8.8.8

2. LAN Configuration:
   - Navigate to: Settings → Networks
   - LAN Network: 192.168.1.0/24
   - Gateway IP: 192.168.1.1
   - DHCP Range: 192.168.1.100 - 192.168.1.199
   - Lease Time: 24 hours

3. Network Isolation:
   - Enable Guest Network: No (unless needed)
   - IoT Network: Create separate if you have IoT devices

EOF
}

configure_port_forwarding() {
    log_info "=== Port Forwarding Configuration ==="
    cat << EOF

Navigate to: Settings → Routing & Firewall → Port Forwarding

## HTTP/HTTPS Traffic (Primary Routes)
Name: "Web-Traffic-HTTP"
Protocol: TCP
WAN Port: 80
LAN IP: ${INFRASTRUCTURE_IP}
LAN Port: 80
Description: "HTTP traffic to infrastructure Traefik"

Name: "Web-Traffic-HTTPS"  
Protocol: TCP
WAN Port: 443
LAN IP: ${INFRASTRUCTURE_IP}
LAN Port: 443
Description: "HTTPS traffic to infrastructure Traefik"

## SSH Access (Secure Remote Access)
Name: "SSH-Infrastructure"
Protocol: TCP
WAN Port: 22
LAN IP: ${INFRASTRUCTURE_IP}
LAN Port: 22
Description: "SSH to infrastructure server"

Name: "SSH-Proxmox"
Protocol: TCP  
WAN Port: 2222
LAN IP: ${PROXMOX_IP}
LAN Port: 22
Description: "SSH to Proxmox host"

## Management Interfaces (VPN Recommended)
Name: "Proxmox-WebUI"
Protocol: TCP
WAN Port: 8006
LAN IP: ${PROXMOX_IP}
LAN Port: 8006
Description: "Proxmox web interface (use VPN)"
Enabled: No (Enable only when needed)

Name: "QNAP-WebUI"
Protocol: TCP
WAN Port: 8443
LAN IP: ${QNAP_IP}
LAN Port: 443
Description: "QNAP web interface (use VPN)"
Enabled: No (Enable only when needed)

## Optional: Direct Dokploy Access (for troubleshooting)
Name: "Dokploy-Dev-Direct"
Protocol: TCP
WAN Port: 3030
LAN IP: ${DOKPLOY_DEV_IP}
LAN Port: 3000
Description: "Direct Dokploy dev access"
Enabled: No (Enable only for troubleshooting)

Name: "Dokploy-Prod-Direct"
Protocol: TCP
WAN Port: 3050
LAN IP: ${DOKPLOY_PROD_IP}
LAN Port: 3000
Description: "Direct Dokploy prod access"
Enabled: No (Enable only for troubleshooting)

EOF
}

configure_firewall_rules() {
    log_info "=== Firewall Configuration ==="
    cat << EOF

Navigate to: Settings → Routing & Firewall → Firewall Rules

## Internet Access Rules (WAN_IN)

Rule 1: "Allow-Web-Traffic"
Action: Accept
Protocol: TCP
Source: Any
Destination: ${INFRASTRUCTURE_IP}
Destination Ports: 80, 443
Description: "Allow HTTP/HTTPS to infrastructure"

Rule 2: "Allow-SSH-Infrastructure"
Action: Accept
Protocol: TCP
Source: Any
Destination: ${INFRASTRUCTURE_IP}
Destination Port: 22
Description: "Allow SSH to infrastructure server"

Rule 3: "Block-Direct-Internal-Access"
Action: Drop
Protocol: Any
Source: Any
Destination: 192.168.1.0/24
Description: "Block direct access to internal IPs"
Note: This rule should be AFTER the allow rules above

## LAN Rules (LAN_IN)

Rule 4: "Allow-DNS-AdGuard"
Action: Accept
Protocol: TCP/UDP
Source: 192.168.1.0/24
Destination: ${ADGUARD_PRIMARY_IP}, ${ADGUARD_SECONDARY_IP}
Destination Port: 53
Description: "Allow DNS queries to AdGuard"

Rule 5: "Allow-Infrastructure-Services"
Action: Accept
Protocol: TCP
Source: 192.168.1.0/24
Destination: ${INFRASTRUCTURE_IP}, ${MONITORING_IP}
Destination Ports: 80, 443, 8080, 3000, 9090, 9093
Description: "Allow access to infrastructure services"

Rule 6: "Allow-Storage-NFS"
Action: Accept
Protocol: TCP/UDP
Source: 192.168.1.0/24
Destination: ${QNAP_IP}
Destination Ports: 2049, 111, 443, 80
Description: "Allow NFS and QNAP web access"

Rule 7: "Allow-Proxmox-Internal"
Action: Accept
Protocol: TCP
Source: 192.168.1.0/24
Destination: ${PROXMOX_IP}
Destination Ports: 8006, 5900-5999
Description: "Allow Proxmox access from internal network"

## VPN Access Rules (add after VPN configuration)

Rule 8: "VPN-Full-Access"
Action: Accept
Protocol: Any
Source: ${VPN_NETWORK}
Destination: 192.168.1.0/24
Description: "Allow VPN clients full internal access"

EOF
}

configure_quality_of_service() {
    log_info "=== Quality of Service (QoS) Configuration ==="
    cat << EOF

Navigate to: Settings → Internet → Quality of Service

## Smart Queue Configuration
Enable Smart Queues: Yes
Download Bandwidth: [Your actual download speed - 10%] Mbps
Upload Bandwidth: [Your actual upload speed - 10%] Mbps

## Traffic Rules (if advanced QoS needed)

Priority 1 (Highest): "Critical-Infrastructure"
Targets: ${INFRASTRUCTURE_IP}, ${ADGUARD_PRIMARY_IP}, ${ADGUARD_SECONDARY_IP}
Rate Limit: No limit
Description: "Critical infrastructure services"

Priority 2 (High): "Production-Applications"
Targets: ${DOKPLOY_PROD_IP}
Rate Limit: 80% of available bandwidth
Description: "Production application traffic"

Priority 3 (Medium): "Staging-Applications"  
Targets: ${DOKPLOY_STAGING_IP}
Rate Limit: 60% of available bandwidth
Description: "Staging application traffic"

Priority 4 (Normal): "Development-Applications"
Targets: ${DOKPLOY_DEV_IP}
Rate Limit: 40% of available bandwidth
Description: "Development application traffic"

Priority 5 (Low): "Backup-Traffic"
Targets: ${QNAP_IP}
Ports: 22, 873, 2049
Rate Limit: 20% of available bandwidth
Description: "Backup and sync traffic"

EOF
}

configure_vpn_server() {
    log_info "=== VPN Server Configuration ==="
    cat << EOF

Navigate to: Settings → VPN → VPN Server

## WireGuard VPN Server
VPN Type: WireGuard
Interface: wg0
Listen Port: 51820
VPN Subnet: ${VPN_NETWORK}
DNS Servers: ${ADGUARD_PRIMARY_IP}, ${ADGUARD_SECONDARY_IP}

## VPN Routes
Route 1: 192.168.1.0/24 (Full LAN access)

## Client Configuration Examples

### Admin Client
Name: "admin-laptop"
IP Address: 10.10.10.2/24
Allowed IPs: 192.168.1.0/24
Description: "Administrator full access"

### Developer Client
Name: "developer-laptop"  
IP Address: 10.10.10.3/24
Allowed IPs: 192.168.1.30/32, 192.168.1.40/32, 192.168.1.26/32
Description: "Developer access to dev/staging + monitoring"

### Remote Monitoring
Name: "monitoring-client"
IP Address: 10.10.10.4/24
Allowed IPs: 192.168.1.26/32, 192.168.1.20/32
Description: "Monitoring and DNS access only"

## Security Settings
Key Rotation: Every 90 days
Max Clients: 10
Idle Timeout: 3600 seconds

EOF
}

configure_intrusion_detection() {
    log_info "=== Intrusion Detection & Security ==="
    cat << EOF

Navigate to: Settings → Security → Threat Detection

## IDS/IPS Configuration
Enable IDS/IPS: Yes
Detection Mode: Detection and Prevention
Signature Database: Auto-update enabled
Block Malicious IPs: Yes
Log Security Events: Yes

## DPI (Deep Packet Inspection)
Enable DPI: Yes
Application Detection: Yes
Category-based Blocking: Yes

## Blocked Categories (Recommended)
- Malware & Phishing
- Adult Content (if desired)
- Gambling (if desired)  
- P2P/BitTorrent (for production networks)
- Social Media (during work hours, optional)

## Geo-IP Blocking (Optional)
Block Countries: Configure based on your needs
Common blocks: Known high-risk countries for cyber attacks

## Rate Limiting
SSH Brute Force Protection: Yes
HTTP/HTTPS Rate Limiting: Yes (1000 requests/minute per IP)

## Logging
Syslog Server: ${MONITORING_IP}:514
Log Level: Information
Retention: 30 days

EOF
}

configure_network_optimization() {
    log_info "=== Network Optimization ==="
    cat << EOF

Navigate to: Settings → System → Advanced

## Performance Optimization

Hardware Offloading: Enable (if supported)
Flow Control: Enable
Jumbo Frames: Disable (unless all devices support 9000 MTU)

## DNS Optimization
DNS Cache Size: 150MB
DNS Cache TTL: 300 seconds
DNSSEC Validation: Enable

## Connection Tracking
Connection Timeout: 3600 seconds
Max Connections: 65536
Connection Tracking: Enable

## Buffer Optimization  
TCP Buffer Sizes: Auto
UDP Buffer Sizes: Auto
Network Buffers: Auto

## Bandwidth Monitor
Enable Bandwidth Monitoring: Yes
Historical Data: 30 days
Per-client Tracking: Yes

EOF
}

configure_monitoring_alerting() {
    log_info "=== Monitoring & Alerting ==="
    cat << EOF

Navigate to: Settings → System → Maintenance

## SNMP Configuration (for monitoring)
Enable SNMP: Yes
SNMP Version: v3
Community String: [Generate secure string]
Contact: admin@${DOMAIN_NAME}
Location: Homelab

## Email Alerts
SMTP Server: smtp.gmail.com:587
Username: alerts@${DOMAIN_NAME}  
Password: [App-specific password]
From Address: ucg-ultra@${DOMAIN_NAME}
Recipients: admin@${DOMAIN_NAME}

## Alert Conditions
High CPU Usage: >85% for 5 minutes
High Memory Usage: >90% for 5 minutes
Interface Down: Immediate
VPN Disconnection: Immediate
Failed Login Attempts: >5 in 10 minutes
Firmware Updates: Available

## Network Scanning
Port Scan Detection: Enable
Network Discovery: Enable
Client Isolation: Disable (for homelab)

## Backup Configuration
Auto-backup Settings: Weekly
Backup Location: ${QNAP_IP}:/share/configs/ucg-ultra
Retention: 12 backups

EOF
}

configure_load_balancing() {
    log_info "=== Load Balancing Configuration ==="
    cat << EOF

Navigate to: Settings → Routing & Firewall → Load Balancing

NOTE: UCG Ultra provides intelligent port forwarding, not traditional load balancing.
For true load balancing, configure the infrastructure Traefik server.

## Health Check Configuration

Health Check 1: "Infrastructure-Traefik"
Target: ${INFRASTRUCTURE_IP}:80
Protocol: HTTP
Path: /ping
Interval: 30 seconds
Timeout: 5 seconds
Retries: 3

Health Check 2: "Dokploy-Production"
Target: ${DOKPLOY_PROD_IP}:3000
Protocol: HTTP
Path: /health
Interval: 60 seconds
Timeout: 10 seconds
Retries: 2

## Failover Rules

Rule 1: "Web-Traffic-Failover"
Primary: ${INFRASTRUCTURE_IP}:80,443
Secondary: ${DOKPLOY_PROD_IP}:80,443
Health Check: Infrastructure-Traefik
Failover Time: 30 seconds

Note: Configure multiple Traefik instances for true high availability

EOF
}

generate_validation_script() {
    log_info "=== Validation Script ==="
    cat << 'EOF'

## UCG Ultra Configuration Validation

After applying the configuration, run these tests:

### 1. Basic Connectivity Test
```bash
# Test internet connectivity
ping -c 3 8.8.8.8

# Test DNS resolution via AdGuard
nslookup google.com 192.168.1.20
nslookup google.com 192.168.1.21

# Test internal DNS resolution
nslookup proxmox.lab.local 192.168.1.20
```

### 2. Port Forwarding Test
```bash
# Test HTTP/HTTPS forwarding (from external network)
curl -I http://your-domain.com
curl -I https://your-domain.com

# Test SSH forwarding
ssh user@your-domain.com
ssh -p 2222 user@your-domain.com  # Proxmox SSH
```

### 3. Firewall Test
```bash
# Test blocked direct access (should fail)
telnet your-public-ip 3000

# Test allowed services (should succeed)
telnet your-public-ip 80
telnet your-public-ip 443
```

### 4. VPN Test
```bash
# Connect VPN client and test
ping 192.168.1.1  # Should reach UCG Ultra
ping 192.168.1.10  # Should reach Proxmox
```

### 5. QoS Test
```bash
# Monitor bandwidth usage
# UCG Ultra UI → Insights → Client Usage
# Verify traffic prioritization is working
```

### 6. Security Test
```bash
# Check IDS/IPS logs
# UCG Ultra UI → Events → Security Events
# Verify no false positives on legitimate traffic
```

EOF
}

print_troubleshooting() {
    log_info "=== Troubleshooting Guide ==="
    cat << EOF

## Common Issues and Solutions

### Port Forwarding Not Working
1. Check firewall rules order (allow rules before deny rules)
2. Verify target IP addresses are correct and reachable
3. Test from external network (not internal)
4. Check ISP doesn't block common ports

### DNS Issues
1. Verify AdGuard Home is running on target IPs
2. Check DNS server order in UCG Ultra settings
3. Test with alternative DNS servers (1.1.1.1, 8.8.8.8)
4. Clear DNS cache on client devices

### VPN Connection Problems
1. Check port 51820 is open on WAN
2. Verify client configuration matches server settings
3. Check for NAT/firewall blocking UDP 51820
4. Test with different VPN clients

### Performance Issues
1. Monitor CPU/memory usage in UCG Ultra UI
2. Check for DPI false positives blocking traffic
3. Verify QoS settings aren't overly restrictive
4. Test with QoS temporarily disabled

### Security Alerts
1. Review IDS/IPS logs for false positives
2. Whitelist known good traffic patterns
3. Adjust detection sensitivity if needed
4. Monitor for actual security threats

## Getting Support

1. UCG Ultra Documentation: https://help.ui.com/
2. UniFi Community: https://community.ui.com/
3. Enterprise Homelab Issues: GitHub repository
4. Ubiquiti Support: For hardware/firmware issues

EOF
}

print_security_recommendations() {
    log_info "=== Security Recommendations ==="
    cat << EOF

## Security Best Practices

### 1. Regular Updates
- Enable automatic firmware updates for security patches
- Monitor Ubiquiti security advisories
- Update UniFi Network Controller regularly

### 2. Access Control
- Use VPN for all management interface access
- Disable WAN access to management ports when not needed
- Implement strong passwords for all accounts
- Enable two-factor authentication where available

### 3. Network Segmentation
- Consider VLAN setup for enhanced security
- Isolate IoT devices on separate network
- Limit inter-VLAN communication as needed

### 4. Monitoring
- Enable comprehensive logging
- Set up alerting for security events
- Regular review of firewall logs
- Monitor for unusual traffic patterns

### 5. Backup and Recovery
- Regular configuration backups
- Test restore procedures
- Document all custom configurations
- Maintain offline backup copies

### 6. Incident Response
- Document security incident procedures
- Maintain contact information for key personnel
- Regular security assessment and testing
- Keep security team informed of infrastructure changes

EOF
}

main() {
    print_header
    
    log_warning "IMPORTANT: Customize the IP addresses at the top of this script before use!"
    log_warning "Current configuration assumes single network setup (192.168.1.0/24)"
    echo ""
    
    configure_basic_settings
    configure_port_forwarding
    configure_firewall_rules
    configure_quality_of_service
    configure_vpn_server
    configure_intrusion_detection
    configure_network_optimization
    configure_monitoring_alerting
    configure_load_balancing
    generate_validation_script
    print_troubleshooting
    print_security_recommendations
    
    echo ""
    log_success "UCG Ultra configuration guide generated successfully!"
    echo ""
    log_info "Next Steps:"
    echo "1. Customize IP addresses in this script for your network"
    echo "2. Apply configurations in UniFi Network Controller"
    echo "3. Test each section after implementation"
    echo "4. Run validation scripts to verify functionality"
    echo "5. Set up monitoring and alerting"
    echo ""
    log_info "For VLAN setup, see: network/vlan-setup.md"
    log_info "For advanced configurations, see: docs/architecture.md"
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
EOF
