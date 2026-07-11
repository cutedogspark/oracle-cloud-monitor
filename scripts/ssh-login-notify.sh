#!/bin/bash
# SSH login notification (PAM)
# Sends ntfy notification when SSH login occurs
#
# Installation (automatic via setup-cron.sh or manual):
#   sudo cp scripts/ssh-login-notify.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/ssh-login-notify.sh
#   echo 'session optional pam_exec.so seteuid /usr/local/bin/ssh-login-notify.sh' | sudo tee -a /etc/pam.d/sshd

export SUPPRESS_LABEL_WARNING=True

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_DIR}/.env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# Get login info
USER="${PAM_USER:-unknown}"
RHOST="${PAM_RHOST:-unknown}"
TIME=$(date '+%Y-%m-%d %H:%M:%S')

echo "SSH login detected: user=$USER, from=$RHOST, at=$TIME"
