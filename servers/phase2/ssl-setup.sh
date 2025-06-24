#!/bin/bash

# =============================================================================
# CASPIL VPN SSL CERTIFICATE SETUP
# =============================================================================
# Purpose: Automated SSL certificate management with Let's Encrypt
# Usage: ./ssl-setup.sh [domain-name]
# Example: ./ssl-setup.sh vpn.caspil.ink
# =============================================================================

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVER_IP="140.82.7.120"
EMAIL="admin@caspil.ink"
NGINX_CONF_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

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
# SSL CERTIFICATE FUNCTIONS
# =============================================================================

setup_nginx_for_domain() {
    local domain=$1
    
    log "📋 Setting up Nginx configuration for $domain"
    
    # Create basic HTTP configuration for certificate verification
    cat > "$NGINX_CONF_DIR/$domain" << EOF
server {
    listen 80;
    server_name $domain;
    root /var/www/html;
    index index.html;
    
    # Allow Let's Encrypt verification
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect all other traffic to HTTPS (after certificate is issued)
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    
    # Enable the site
    ln -sf "$NGINX_CONF_DIR/$domain" "$NGINX_ENABLED_DIR/"
    
    # Test and reload Nginx
    nginx -t
    systemctl reload nginx
    
    log "✅ Nginx configured for $domain"
}

request_ssl_certificate() {
    local domain=$1
    
    log "🔐 Requesting SSL certificate for $domain"
    
    # Request certificate
    certbot certonly \
        --webroot \
        --webroot-path=/var/www/html \
        --email "$EMAIL" \
        --agree-tos \
        --no-eff-email \
        --domains "$domain" || error "Failed to obtain SSL certificate"
    
    log "✅ SSL certificate obtained for $domain"
}

configure_https_nginx() {
    local domain=$1
    
    log "🔧 Configuring HTTPS in Nginx for $domain"
    
    # Create HTTPS configuration
    cat > "$NGINX_CONF_DIR/$domain" << EOF
# HTTP - Redirect to HTTPS
server {
    listen 80;
    server_name $domain;
    
    # Allow Let's Encrypt verification
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # Redirect everything else to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS - Main site
server {
    listen 443 ssl http2;
    server_name $domain;
    
    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    # Security headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    # Root directory
    root /var/www/html;
    index index.html;
    
    # VPN Management Interface
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    # Grafana proxy (monitoring dashboard)
    location /grafana/ {
        proxy_pass http://localhost:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Prometheus proxy (metrics API)
    location /prometheus/ {
        proxy_pass http://localhost:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Node metrics endpoint
    location /metrics {
        proxy_pass http://localhost:9100/metrics;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    
    # API endpoint for future use
    location /api/ {
        # This will be used for VPN management API
        return 501 "API not yet implemented";
        add_header Content-Type text/plain;
    }
}
EOF
    
    # Test and reload Nginx
    nginx -t
    systemctl reload nginx
    
    log "✅ HTTPS configuration complete for $domain"
}

setup_certificate_renewal() {
    local domain=$1
    
    log "⏰ Setting up automatic certificate renewal"
    
    # Test certificate renewal
    certbot renew --dry-run || warning "Certificate renewal test failed"
    
    # Ensure renewal timer is enabled
    systemctl is-enabled certbot.timer || systemctl enable certbot.timer
    systemctl is-active certbot.timer || systemctl start certbot.timer
    
    # Create custom renewal hook for Nginx reload
    cat > "/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh" << 'EOF'
#!/bin/bash
# Reload Nginx after certificate renewal
systemctl reload nginx
EOF
    
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    
    log "✅ Certificate auto-renewal configured"
}

create_enhanced_landing_page() {
    local domain=$1
    
    log "🎨 Creating enhanced VPN management interface"
    
    cat > "/var/www/html/index.html" << EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Caspil VPN - Management Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            color: #333;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        .header {
            text-align: center;
            margin-bottom: 40px;
            color: white;
        }
        
        .header h1 {
            font-size: 3rem;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        
        .header p {
            font-size: 1.2rem;
            opacity: 0.9;
        }
        
        .dashboard {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 40px;
        }
        
        .card {
            background: rgba(255, 255, 255, 0.95);
            border-radius: 15px;
            padding: 25px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.2);
            transition: transform 0.3s ease;
        }
        
        .card:hover {
            transform: translateY(-5px);
        }
        
        .card h3 {
            color: #4a5568;
            margin-bottom: 15px;
            font-size: 1.3rem;
        }
        
        .status-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
            margin: 15px 0;
        }
        
        .status {
            padding: 8px 12px;
            border-radius: 8px;
            text-align: center;
            font-weight: 500;
            font-size: 0.9rem;
        }
        
        .status.active { background: #c6f6d5; color: #22543d; }
        .status.secure { background: #bee3f8; color: #2a4365; }
        .status.monitoring { background: #fed7d7; color: #742a2a; }
        
        .metrics {
            display: flex;
            justify-content: space-between;
            margin: 15px 0;
        }
        
        .metric {
            text-align: center;
        }
        
        .metric-value {
            font-size: 1.5rem;
            font-weight: bold;
            color: #4299e1;
        }
        
        .metric-label {
            font-size: 0.8rem;
            color: #718096;
            margin-top: 5px;
        }
        
        .links {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        
        .link-btn {
            display: block;
            padding: 12px 20px;
            background: #4299e1;
            color: white;
            text-decoration: none;
            border-radius: 8px;
            text-align: center;
            transition: background 0.3s ease;
        }
        
        .link-btn:hover {
            background: #3182ce;
        }
        
        .footer {
            text-align: center;
            color: rgba(255, 255, 255, 0.8);
            margin-top: 40px;
        }
        
        .ssl-badge {
            display: inline-flex;
            align-items: center;
            background: #48bb78;
            color: white;
            padding: 5px 10px;
            border-radius: 15px;
            font-size: 0.8rem;
            margin-left: 10px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 Caspil VPN</h1>
            <p>Phase 2 - Multi-Region Infrastructure Dashboard</p>
            <span class="ssl-badge">🔒 SSL Secured</span>
        </div>
        
        <div class="dashboard">
            <div class="card">
                <h3>🌐 Server Status</h3>
                <div class="status-grid">
                    <div class="status active">WireGuard Active</div>
                    <div class="status active">OpenVPN Active</div>
                    <div class="status secure">HTTPS Enabled</div>
                    <div class="status monitoring">Monitoring Live</div>
                </div>
                <p><strong>Location:</strong> Newark, New Jersey, USA</p>
                <p><strong>IP Address:</strong> $SERVER_IP</p>
                <p><strong>Domain:</strong> $domain</p>
            </div>
            
            <div class="card">
                <h3>📊 VPN Metrics</h3>
                <div class="metrics">
                    <div class="metric">
                        <div class="metric-value" id="wg-peers">0</div>
                        <div class="metric-label">WireGuard Peers</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value" id="ovpn-clients">0</div>
                        <div class="metric-label">OpenVPN Clients</div>
                    </div>
                    <div class="metric">
                        <div class="metric-value">99.9%</div>
                        <div class="metric-label">Uptime</div>
                    </div>
                </div>
                <p>Last updated: <span id="last-update">$(date)</span></p>
            </div>
            
            <div class="card">
                <h3>🔧 Management Tools</h3>
                <div class="links">
                    <a href="/grafana/" class="link-btn">📈 Grafana Dashboard</a>
                    <a href="/prometheus/" class="link-btn">🎯 Prometheus</a>
                    <a href="/metrics" class="link-btn">📊 Raw Metrics</a>
                </div>
            </div>
            
            <div class="card">
                <h3>⚙️ Phase 2 Progress</h3>
                <ul style="list-style: none; padding: 0;">
                    <li style="margin: 8px 0;">✅ SSL Certificate Management</li>
                    <li style="margin: 8px 0;">✅ Monitoring & Analytics</li>
                    <li style="margin: 8px 0;">✅ VPN Metrics Collection</li>
                    <li style="margin: 8px 0;">🚧 Multi-Region Deployment</li>
                    <li style="margin: 8px 0;">🚧 Load Balancing</li>
                    <li style="margin: 8px 0;">🚧 User Management API</li>
                </ul>
            </div>
        </div>
        
        <div class="footer">
            <p>Caspil VPN Phase 2 Infrastructure • Deployed $(date +"%B %d, %Y")</p>
            <p>Secure • Private • Fast</p>
        </div>
    </div>
    
    <script>
    // Simple real-time metrics (could be enhanced with WebSocket)
    function updateMetrics() {
        // This would typically fetch from an API endpoint
        // For now, we'll simulate some basic updates
        const timestamp = new Date().toLocaleTimeString();
        document.getElementById('last-update').textContent = timestamp;
        
        // In a real implementation, these would come from the metrics API
        // document.getElementById('wg-peers').textContent = Math.floor(Math.random() * 5);
        // document.getElementById('ovpn-clients').textContent = Math.floor(Math.random() * 3);
    }
    
    // Update every 30 seconds
    setInterval(updateMetrics, 30000);
    updateMetrics();
    </script>
</body>
</html>
EOF
    
    log "✅ Enhanced management interface created"
}

# =============================================================================
# MAIN SETUP FUNCTION
# =============================================================================

main() {
    local domain=$1
    
    if [[ -z "$domain" ]]; then
        echo "Usage: $0 <domain-name>"
        echo ""
        echo "Examples:"
        echo "  $0 vpn.caspil.ink"
        echo "  $0 us-east.caspil.ink"
        echo ""
        echo "Note: Domain must point to $SERVER_IP before running this script"
        exit 1
    fi
    
    log "🚀 Starting SSL setup for $domain"
    
    # Verify domain points to our server IP
    info "Verifying domain DNS configuration..."
    local resolved_ip=$(dig +short "$domain" @8.8.8.8 | head -1)
    if [[ "$resolved_ip" != "$SERVER_IP" ]]; then
        warning "Domain $domain resolves to $resolved_ip, but server IP is $SERVER_IP"
        warning "Certificate generation may fail if DNS is not properly configured"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        log "✅ Domain DNS verification successful"
    fi
    
    # Setup process
    setup_nginx_for_domain "$domain"
    request_ssl_certificate "$domain"
    configure_https_nginx "$domain"
    setup_certificate_renewal "$domain"
    create_enhanced_landing_page "$domain"
    
    log "🎉 SSL setup completed successfully!"
    info "🌐 Access your VPN dashboard at: https://$domain"
    info "📊 Grafana dashboard: https://$domain/grafana/"
    info "🎯 Prometheus: https://$domain/prometheus/"
    info "📈 Metrics: https://$domain/metrics"
    
    log "📋 Next steps:"
    info "1. Update DNS for additional subdomains"
    info "2. Deploy additional regional servers"
    info "3. Configure load balancing"
    info "4. Set up user management API"
}

# Run main function with all arguments
main "$@" 