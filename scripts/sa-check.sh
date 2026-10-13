#!/bin/bash
# ============================================================================
# sa-check.sh - Server health check agent
#
# Version   : 1.1.0
# Author    : Eng. Samir Abou El Khair
# Copyright : (c) 2026 Eng. Samir Abou El Khair
# License   : MIT (see LICENSE)
#
# Checks the local server (core services + disk/RAM/load) and pushes the
# result to an n8n webhook over outbound HTTPS. No inbound port is opened,
# so it is safe on production cPanel/WHM servers that host client sites.
#
# Configuration lives in /etc/sa-check.conf (written by install.sh):
#   WEBHOOK_URL="https://your-n8n/webhook/sa-check"
#   SA_TOKEN=""            # optional shared secret, sent as X-SA-Token
# ============================================================================

set -uo pipefail

SA_CHECK_VERSION="1.1.0"
CONF_FILE="/etc/sa-check.conf"
WEBHOOK_URL=""
SA_TOKEN=""

# shellcheck disable=SC1090
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

if [[ -z "$WEBHOOK_URL" ]]; then
    echo "sa-check: WEBHOOK_URL is not set (expected in $CONF_FILE)" >&2
    exit 1
fi

SERVER_NAME=$(hostname -s)
SERVER_FQDN=$(hostname -f 2>/dev/null || hostname)
SERVER_IP=$(hostname -I | awk '{print $1}')

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

# Service unit names differ between distributions (httpd/apache2,
# mysqld/mariadb/mysql). Use whichever candidate is actually active; if none
# is active, fall back to the first name so the status correctly reads
# "stopped".
detect_service() {
    local svc
    for svc in "$@"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "$svc"
            return
        fi
    done
    echo "$1"
}

APACHE_SVC=$(detect_service "httpd" "apache2")
DB_SVC=$(detect_service "mysqld" "mariadb" "mysql")

APACHE_STATUS=$(check_service "$APACHE_SVC")
MARIADB_STATUS=$(check_service "$DB_SVC")
EXIM_STATUS=$(check_service "exim")
DOVECOT_STATUS=$(check_service "dovecot")
PHPFPM_STATUS=$(check_service "php-fpm")

DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
RAM_USAGE=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')
LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')

# The final alert decision is made centrally in n8n (Company Lookup node), so
# this local status is informational only.
STATUS="ok"
if [[ "$APACHE_STATUS" == "stopped" || "$MARIADB_STATUS" == "stopped" || \
      "$EXIM_STATUS" == "stopped" || "$DOVECOT_STATUS" == "stopped" ]]; then
    STATUS="critical"
elif [[ "$DISK_USAGE" -ge 90 || "$RAM_USAGE" -ge 90 ]]; then
    STATUS="warning"
fi

PAYLOAD=$(cat <<EOF
{
  "version": "$SA_CHECK_VERSION",
  "server": "$SERVER_NAME",
  "hostname": "$SERVER_FQDN",
  "ip": "$SERVER_IP",
  "status": "$STATUS",
  "services": {
    "apache": "$APACHE_STATUS",
    "mariadb": "$MARIADB_STATUS",
    "exim": "$EXIM_STATUS",
    "dovecot": "$DOVECOT_STATUS",
    "php-fpm": "$PHPFPM_STATUS"
  },
  "resources": {
    "disk_usage_percent": $DISK_USAGE,
    "ram_usage_percent": $RAM_USAGE,
    "load_avg": "$LOAD_AVG"
  },
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
)

CURL_ARGS=(-s -X POST "$WEBHOOK_URL" -H "Content-Type: application/json"
           -d "$PAYLOAD" --max-time 10 --output /dev/null)
[[ -n "$SA_TOKEN" ]] && CURL_ARGS+=(-H "X-SA-Token: $SA_TOKEN")

curl "${CURL_ARGS[@]}"

echo "$PAYLOAD"
