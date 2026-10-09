#!/bin/zsh
# Removes Headless. Settings in ~/Library/Application Support/Headless are kept.
# Usage: sudo scripts/uninstall.sh
set -eu
[[ $EUID == 0 ]] || exec sudo "$0" "$@"
user=${SUDO_USER:?run this with sudo from your own account}
uid=$(id -u "$user")
launchctl bootout "gui/$uid/dev.jesvi.headless" 2>/dev/null || true
rm -f /Library/LaunchAgents/dev.jesvi.headless.plist
rm -rf /Applications/Headless.app
echo "Removed Headless. The built-in display stays disabled until restart or 'Headless headless off'."
