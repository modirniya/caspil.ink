#!/bin/bash

# =============================================================================
# CASPIL VPN METRICS COLLECTOR
# =============================================================================
# Purpose: Collect VPN-specific metrics for Prometheus monitoring
# Usage: Run as a cron job every minute
# Output: Prometheus-formatted metrics to /var/lib/node_exporter/textfile_collector/
# =============================================================================

set -e

METRICS_DIR="/var/lib/node_exporter/textfile_collector"
TEMP_FILE="/tmp/vpn_metrics.prom.$$"

# Ensure metrics directory exists
mkdir -p "$METRICS_DIR"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Get current timestamp for metrics
get_timestamp() {
    date +%s000  # Milliseconds
}

# Write metric with help and type
write_metric() {
    local name=$1
    local type=$2
    local help=$3
    local value=$4
    local labels=$5
    
    echo "# HELP $name $help" >> "$TEMP_FILE"
    echo "# TYPE $name $type" >> "$TEMP_FILE"
    if [[ -n "$labels" ]]; then
        echo "${name}{${labels}} $value" >> "$TEMP_FILE"
    else
        echo "$name $value" >> "$TEMP_FILE"
    fi
    echo "" >> "$TEMP_FILE"
}

# =============================================================================
# WIREGUARD METRICS
# =============================================================================

collect_wireguard_metrics() {
    if ! command -v wg &> /dev/null; then
        return
    fi
    
    # Check if WireGuard interface is active
    if systemctl is-active --quiet wg-quick@wg0; then
        write_metric "vpn_wireguard_interface_up" "gauge" "WireGuard interface status (1=up, 0=down)" "1" 'interface="wg0"'
        
        # Get WireGuard interface stats
        local wg_stats=$(wg show wg0 dump 2>/dev/null || echo "")
        if [[ -n "$wg_stats" ]]; then
            local peer_count=0
            local total_rx=0
            local total_tx=0
            
            while IFS=$'\t' read -r public_key preshared_key endpoint allowed_ips latest_handshake transfer_rx transfer_tx persistent_keepalive; do
                if [[ "$public_key" != "public-key" ]]; then  # Skip header
                    ((peer_count++))
                    total_rx=$((total_rx + transfer_rx))
                    total_tx=$((total_tx + transfer_tx))
                    
                    # Peer-specific metrics
                    local peer_label="peer=\"${public_key:0:8}...\""
                    
                    # Latest handshake (seconds ago)
                    local handshake_age=0
                    if [[ "$latest_handshake" != "0" ]]; then
                        handshake_age=$(($(date +%s) - latest_handshake))
                    fi
                    
                    write_metric "vpn_wireguard_peer_last_handshake_seconds" "gauge" "Seconds since last WireGuard peer handshake" "$handshake_age" "$peer_label"
                    write_metric "vpn_wireguard_peer_transfer_rx_bytes" "counter" "WireGuard peer received bytes" "$transfer_rx" "$peer_label"
                    write_metric "vpn_wireguard_peer_transfer_tx_bytes" "counter" "WireGuard peer transmitted bytes" "$transfer_tx" "$peer_label"
                fi
            done <<< "$wg_stats"
            
            # Interface-level metrics
            write_metric "vpn_wireguard_peers_count" "gauge" "Number of WireGuard peers" "$peer_count" 'interface="wg0"'
            write_metric "vpn_wireguard_transfer_rx_bytes_total" "counter" "Total WireGuard received bytes" "$total_rx" 'interface="wg0"'
            write_metric "vpn_wireguard_transfer_tx_bytes_total" "counter" "Total WireGuard transmitted bytes" "$total_tx" 'interface="wg0"'
        fi
    else
        write_metric "vpn_wireguard_interface_up" "gauge" "WireGuard interface status (1=up, 0=down)" "0" 'interface="wg0"'
    fi
}

# =============================================================================
# OPENVPN METRICS
# =============================================================================

collect_openvpn_metrics() {
    # Check if OpenVPN service is active
    if systemctl is-active --quiet openvpn@server; then
        write_metric "vpn_openvpn_service_up" "gauge" "OpenVPN service status (1=up, 0=down)" "1" 'service="server"'
        
        # Parse OpenVPN status file
        local status_file="/etc/openvpn/openvpn-status.log"
        if [[ -f "$status_file" ]]; then
            local connected_clients=0
            local total_bytes_in=0
            local total_bytes_out=0
            
            # Parse client connections
            while IFS=',' read -r common_name real_address virtual_address bytes_received bytes_sent connected_since; do
                if [[ "$common_name" != "Common Name" && "$common_name" != "ROUTING TABLE" && -n "$common_name" ]]; then
                    ((connected_clients++))
                    total_bytes_in=$((total_bytes_in + bytes_received))
                    total_bytes_out=$((total_bytes_out + bytes_sent))
                    
                    # Client-specific metrics
                    local client_label="client=\"$common_name\""
                    write_metric "vpn_openvpn_client_bytes_received" "counter" "OpenVPN client bytes received" "$bytes_received" "$client_label"
                    write_metric "vpn_openvpn_client_bytes_sent" "counter" "OpenVPN client bytes sent" "$bytes_sent" "$client_label"
                fi
            done < <(grep -A 100 "CLIENT LIST" "$status_file" | grep -B 100 "ROUTING TABLE" | grep "^[^,]*,")
            
            write_metric "vpn_openvpn_connected_clients" "gauge" "Number of connected OpenVPN clients" "$connected_clients" 'service="server"'
            write_metric "vpn_openvpn_bytes_received_total" "counter" "Total OpenVPN bytes received" "$total_bytes_in" 'service="server"'
            write_metric "vpn_openvpn_bytes_sent_total" "counter" "Total OpenVPN bytes sent" "$total_bytes_out" 'service="server"'
        fi
    else
        write_metric "vpn_openvpn_service_up" "gauge" "OpenVPN service status (1=up, 0=down)" "0" 'service="server"'
        write_metric "vpn_openvpn_connected_clients" "gauge" "Number of connected OpenVPN clients" "0" 'service="server"'
    fi
}

# =============================================================================
# SYSTEM METRICS
# =============================================================================

collect_system_metrics() {
    # Network interface statistics
    local eth0_stats=""
    if [[ -f "/sys/class/net/eth0/statistics/rx_bytes" ]]; then
        local rx_bytes=$(cat /sys/class/net/eth0/statistics/rx_bytes)
        local tx_bytes=$(cat /sys/class/net/eth0/statistics/tx_bytes)
        local rx_packets=$(cat /sys/class/net/eth0/statistics/rx_packets)
        local tx_packets=$(cat /sys/class/net/eth0/statistics/tx_packets)
        
        write_metric "vpn_server_network_rx_bytes_total" "counter" "Network interface received bytes" "$rx_bytes" 'interface="eth0"'
        write_metric "vpn_server_network_tx_bytes_total" "counter" "Network interface transmitted bytes" "$tx_bytes" 'interface="eth0"'
        write_metric "vpn_server_network_rx_packets_total" "counter" "Network interface received packets" "$rx_packets" 'interface="eth0"'
        write_metric "vpn_server_network_tx_packets_total" "counter" "Network interface transmitted packets" "$tx_packets" 'interface="eth0"'
    fi
    
    # Active connections
    local tcp_connections=$(ss -t | grep -c ESTAB || echo 0)
    local udp_connections=$(ss -u | wc -l || echo 0)
    
    write_metric "vpn_server_tcp_connections" "gauge" "Number of established TCP connections" "$tcp_connections"
    write_metric "vpn_server_udp_connections" "gauge" "Number of UDP connections" "$udp_connections"
    
    # Load average
    local load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    write_metric "vpn_server_load_1min" "gauge" "1-minute load average" "$load_1min"
    
    # Available disk space (percentage)
    local disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    local disk_available=$((100 - disk_usage))
    write_metric "vpn_server_disk_available_percent" "gauge" "Available disk space percentage" "$disk_available"
}

# =============================================================================
# SERVICE HEALTH METRICS
# =============================================================================

collect_service_health() {
    # Check critical services
    local services=("nginx" "ufw" "prometheus-node-exporter")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            write_metric "vpn_service_up" "gauge" "Service status (1=up, 0=down)" "1" "service=\"$service\""
        else
            write_metric "vpn_service_up" "gauge" "Service status (1=up, 0=down)" "0" "service=\"$service\""
        fi
    done
    
    # Certificate expiry check (if certificates exist)
    local cert_path="/etc/letsencrypt/live"
    if [[ -d "$cert_path" ]]; then
        for cert_dir in "$cert_path"/*; do
            if [[ -d "$cert_dir" && -f "$cert_dir/cert.pem" ]]; then
                local domain=$(basename "$cert_dir")
                local expiry_date=$(openssl x509 -enddate -noout -in "$cert_dir/cert.pem" | cut -d= -f2)
                local expiry_timestamp=$(date -d "$expiry_date" +%s)
                local current_timestamp=$(date +%s)
                local days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
                
                write_metric "vpn_ssl_cert_days_until_expiry" "gauge" "Days until SSL certificate expires" "$days_until_expiry" "domain=\"$domain\""
            fi
        done
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    # Clear temporary file
    > "$TEMP_FILE"
    
    # Add metadata
    cat >> "$TEMP_FILE" << EOF
# VPN Metrics Collection - $(date -Iseconds)
# Generated by Caspil VPN Metrics Collector

EOF
    
    # Collect all metrics
    collect_wireguard_metrics
    collect_openvpn_metrics
    collect_system_metrics
    collect_service_health
    
    # Atomically move metrics file to final location
    mv "$TEMP_FILE" "$METRICS_DIR/vpn_metrics.prom"
    
    # Set proper permissions
    chmod 644 "$METRICS_DIR/vpn_metrics.prom"
}

# Execute main function
main "$@" 