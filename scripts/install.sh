#!/bin/bash
# ============================================================================
# install.sh - Installer / updater for sa-check
#
# Author    : Eng. Samir Abou El Khair
# Copyright : (c) 2026 Eng. Samir Abou El Khair
# License   : MIT (see LICENSE)
#
# Usage (run as root):
#   curl -fsSL https://raw.githubusercontent.com/<user>/sa-check/v1.1.0/scripts/install.sh | \
#     SA_REPO="<user>/sa-check" SA_REF="v1.1.0" \
#     SA_WEBHOOK_URL="https://your-n8n/webhook/sa-check" bash
#
# Re-running the same command upgrades the script. The webhook URL is stored
# in /etc/sa-check.conf, so on upgrades SA_WEBHOOK_URL may be omitted.
#
# Environment:
#   SA_REPO         GitHub "user/repo" to download from   (required once you
#                   replace the default below)
#   SA_REF          Branch or tag, e.g. main or v1.1.0     (default: main)
#   SA_WEBHOOK_URL  n8n webhook URL                        (required on first install)
#   SA_TOKEN        Optional shared secret sent as X-SA-Token
# ============================================================================

set -euo pipefail

SA_REPO="${SA_REPO:-YOUR-GITHUB-USER/sa-check}"
SA_REF="${SA_REF:-main}"
RAW="https://raw.githubusercontent.com/${SA_REPO}/${SA_REF}"
SCRIPT_PATH="/usr/local/bin/sa-check.sh"
CONF_FILE="/etc/sa-check.conf"

if [[ $EUID -ne 0 ]]; then
    echo "install.sh must be run as root." >&2
    exit 1
fi

echo "Downloading sa-check (${SA_REPO}@${SA_REF}) ..."
curl -fsSL "${RAW}/scripts/sa-check.sh" -o "${SCRIPT_PATH}.tmp"
bash -n "${SCRIPT_PATH}.tmp"   # refuse to install a script with syntax errors
mv "${SCRIPT_PATH}.tmp" "$SCRIPT_PATH"
chmod 755 "$SCRIPT_PATH"

if [[ -n "${SA_WEBHOOK_URL:-}" ]]; then
    ( umask 077
      printf 'WEBHOOK_URL=%q\nSA_TOKEN=%q\n' "$SA_WEBHOOK_URL" "${SA_TOKEN:-}" > "$CONF_FILE" )
    echo "Wrote $CONF_FILE"
elif [[ ! -f "$CONF_FILE" ]]; then
    echo "SA_WEBHOOK_URL is required on first install." >&2
    exit 1
fi

# Cron entry: output is discarded so cron never e-mails the JSON every minute.
CRON_LINE="* * * * * ${SCRIPT_PATH} > /dev/null 2>&1"
( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true; echo "$CRON_LINE" ) | crontab -
echo "Cron job installed (runs every minute)."

echo
echo "Running a test check ..."
"$SCRIPT_PATH" || true

echo
echo "Done. If this is a new server, add its IP to the Company Lookup node in n8n."
