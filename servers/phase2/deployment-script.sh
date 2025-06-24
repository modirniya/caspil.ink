#!/bin/bash

# =============================================================================
# CASPIL VPN - PHASE 2 MULTI-REGION DEPLOYMENT SCRIPT
# =============================================================================
# Purpose: Automated deployment of VPN servers across multiple regions
# Usage: ./deployment-script.sh [region-code] [server-name]
# Example: ./deployment-script.sh lax us-west
# =============================================================================

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SSH_KEY_ID="16bca3b4-79b7-4d9e-a1b6-3d8b10c20c19"
PLAN="vc2-1c-2gb"
OS_ID="387"  # Ubuntu 22.04 LTS
EXISTING_SERVER_IP="140.82.7.120"

# Region mapping
declare -A REGIONS=(
    ["lax"]="Los Angeles, US West"
    ["lhr"]="London, Europe"
    ["nrt"]="Tokyo, Asia-Pacific"
    ["sgp"]="Singapore, Asia-Pacific"
    ["fra"]="Frankfurt, Europe"
    ["syd"]="Sydney, Asia-Pacific"
)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

deploy_server() {
    local region_code=$1
    local server_name=$2
    local region_name=${REGIONS[$region_code]}
    
    if [[ -z "$region_name" ]]; then
        error "Invalid region code: $region_code"
    fi
    
    log "🚀 Deploying VPN server: $server_name in $region_name"
    
    # Deploy server via Vultr CLI
    local server_info=$(vultr-cli instance create \
        --region "$region_code" \
        --plan "$PLAN" \
        --os "$OS_ID" \
        --ssh-keys "$SSH_KEY_ID" \
        --label "caspil-$server_name" \
        --host "caspil-$server_name" \
        --tags "phase2,vpn-server,$server_name" \
        --ipv6 \
        --output json 2>/dev/null) || error "Failed to deploy server"
    
    local server_id=$(echo "$server_info" | jq -r '.id')
    local server_ip=$(echo "$server_info" | jq -r '.main_ip')
    
    log "✅ Server deployed successfully!"
    info "Server ID: $server_id"
    info "Server IP: $server_ip"
    info "Region: $region_name"
    
    # Wait for server to be ready
    log "⏳ Waiting for server to boot..."
    wait_for_server "$server_ip"
    
    # Configure the server
    configure_vpn_server "$server_ip" "$server_name" "$region_code"
    
    # Add to monitoring
    add_to_monitoring "$server_ip" "$server_name"
    
    log "🎉 Server $server_name ($server_ip) deployed and configured successfully!"
    
    # Save server details
    save_server_details "$server_id" "$server_ip" "$server_name" "$region_code" "$region_name"
}

wait_for_server() {
    local server_ip=$1
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$server_ip" "echo 'Server ready'" &>/dev/null; then
            log "✅ Server is ready and SSH accessible"
            return 0
        fi
        info "Attempt $attempt/$max_attempts - Server not ready yet, waiting..."
        sleep 30
        ((attempt++))
    done
    
    error "Server failed to become ready after $max_attempts attempts"
}

configure_vpn_server() {
    local server_ip=$1
    local server_name=$2
    local region_code=$3
    
    log "⚙️ Configuring VPN services on $server_ip..."
    
    # Create configuration script
    cat > "/tmp/configure_server.sh" << 'EOF'
#!/bin/bash
set -e

echo "🔧 Starting VPN server configuration..."

# Update system
apt update && apt upgrade -y

# Install required packages
apt install -y ufw iptables-persistent wireguard wireguard-tools openvpn easy-rsa nginx

# Configure firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 51820/udp
ufw allow 1194/udp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 9100/tcp  # Node exporter
ufw --force enable

# Enable IP forwarding
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
sysctl -p

# Configure WireGuard
mkdir -p /etc/wireguard
cd /etc/wireguard

# Generate server keys
wg genkey | tee server_private.key | wg pubkey > server_public.key
chmod 600 server_private.key

# Create WireGuard configuration
SERVER_PRIVATE_KEY=$(cat server_private.key)
cat > wg0.conf << EOL
[Interface]
PrivateKey = $SERVER_PRIVATE_KEY
Address = 10.66.66.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

EOL

# Configure OpenVPN
cd /etc/openvpn
cp -r /usr/share/easy-rsa/* .
./easyrsa init-pki
echo 'CaspilVPN' | ./easyrsa build-ca nopass
echo 'server' | ./easyrsa gen-req server nopass
echo 'yes' | ./easyrsa sign-req server server
./easyrsa gen-dh
openvpn --genkey --secret ta.key

# Create OpenVPN server configuration
cat > server.conf << 'EOL'
port 1194
proto udp
dev tun
ca pki/ca.crt
cert pki/issued/server.crt
key pki/private/server.key
dh pki/dh.pem
tls-auth ta.key 0
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status openvpn-status.log
verb 3
EOL

# Enable and start services
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
systemctl enable openvpn@server
systemctl start openvpn@server
systemctl enable nginx
systemctl start nginx

# Install monitoring
apt install -y prometheus-node-exporter
systemctl enable prometheus-node-exporter
systemctl start prometheus-node-exporter

echo "✅ VPN server configuration completed!"
EOF

    # Execute configuration on remote server
    scp -o StrictHostKeyChecking=no "/tmp/configure_server.sh" root@"$server_ip":/tmp/
    ssh -o StrictHostKeyChecking=no root@"$server_ip" "chmod +x /tmp/configure_server.sh && /tmp/configure_server.sh"
    
    # Clean up
    rm "/tmp/configure_server.sh"
    
    log "✅ VPN configuration completed for $server_name"
}

add_to_monitoring() {
    local server_ip=$1
    local server_name=$2
    
    log "📊 Adding $server_name to monitoring system..."
    
    # Add to Prometheus configuration on main server
    ssh -o StrictHostKeyChecking=no root@"$EXISTING_SERVER_IP" "
    # Add new target to Prometheus
    cat >> /etc/prometheus/prometheus.yml << EOL

  - targets:
    - $server_ip:9100
    labels:
      instance: '$server_name'
      region: '$server_name'
EOL
    
    # Reload Prometheus
    systemctl reload prometheus
    "
    
    log "✅ $server_name added to monitoring"
}

save_server_details() {
    local server_id=$1
    local server_ip=$2
    local server_name=$3
    local region_code=$4
    local region_name=$5
    
    # Create server details file
    cat > "servers/phase2/$server_name-details.md" << EOF
# $server_name Server Details

## Basic Information
- **Server Name**: $server_name
- **Server ID**: $server_id
- **IP Address**: $server_ip
- **Region Code**: $region_code
- **Region**: $region_name
- **Plan**: $PLAN
- **OS**: Ubuntu 22.04 LTS
- **Deployment Date**: $(date)

## VPN Configuration
- **WireGuard**: Port 51820/UDP, Network 10.66.66.0/24
- **OpenVPN**: Port 1194/UDP, Network 10.8.0.0/24
- **Management**: Port 80/443 (HTTPS)

## Access Information  
- **SSH**: ssh root@$server_ip
- **Web Interface**: http://$server_ip
- **Monitoring**: http://$server_ip:9100/metrics

## Service Status Commands
\`\`\`bash
# Check VPN services
systemctl status wg-quick@wg0
systemctl status openvpn@server

# Check monitoring
systemctl status prometheus-node-exporter
curl http://localhost:9100/metrics | head -10
\`\`\`

## Client Configuration
### WireGuard Client Template
\`\`\`ini
[Interface]
PrivateKey = CLIENT_PRIVATE_KEY
Address = 10.66.66.X/32
DNS = 8.8.8.8

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = $server_ip:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
\`\`\`

### OpenVPN Client Commands
\`\`\`bash
# Generate client certificate on server
cd /etc/openvpn
echo 'client1' | ./easyrsa gen-req client1 nopass
echo 'yes' | ./easyrsa sign-req client client1

# Download client configuration
scp root@$server_ip:/etc/openvpn/client1.ovpn ./
\`\`\`

---
*Server deployed as part of Caspil VPN Phase 2 - Multi-Region Infrastructure*
EOF

    log "📝 Server details saved to servers/phase2/$server_name-details.md"
}

# =============================================================================
# MAIN DEPLOYMENT LOGIC
# =============================================================================

main() {
    local region_code=$1
    local server_name=$2
    
    if [[ -z "$region_code" || -z "$server_name" ]]; then
        echo "Usage: $0 <region-code> <server-name>"
        echo ""
        echo "Available regions:"
        for region in "${!REGIONS[@]}"; do
            echo "  $region - ${REGIONS[$region]}"
        done
        echo ""
        echo "Examples:"
        echo "  $0 lax us-west      # Deploy US West server"
        echo "  $0 lhr europe       # Deploy Europe server"
        echo "  $0 nrt asia         # Deploy Asia server"
        exit 1
    fi
    
    # Verify Vultr CLI is configured
    if ! vultr-cli account info &>/dev/null; then
        error "Vultr CLI not configured. Please run 'vultr-cli configure' first."
    fi
    
    # Create directories if they don't exist
    mkdir -p servers/phase2
    
    log "🚀 Starting Phase 2 deployment for $server_name in ${REGIONS[$region_code]}"
    
    # Deploy and configure server
    deploy_server "$region_code" "$server_name"
    
    log "🎉 Phase 2 deployment completed successfully!"
    log "📋 Next steps:"
    info "1. Test VPN connections to the new server"
    info "2. Update DNS load balancing configuration"
    info "3. Deploy additional regions as needed"
    info "4. Configure SSL certificates for the management interface"
}

# Run main function with all arguments
main "$@" 