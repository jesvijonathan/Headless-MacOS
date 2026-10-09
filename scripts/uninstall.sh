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
launchctl bootout system/dev.jesvi.headless.fand 2>/dev/null || true  # hands fans back to macOS
rm -f /Library/LaunchDaemons/dev.jesvi.headless.fand.plist /Library/PrivilegedHelperTools/dev.jesvi.headless.fand
rm -rf "/Library/Application Support/Headless"
# Put Apple's Control Strip brightness button back if Headless removed it.
if ! sudo -u "$user" defaults read com.apple.controlstrip MiniCustomized 2>/dev/null | grep -q brightness; then
    sudo -u "$user" defaults delete com.apple.controlstrip MiniCustomized 2>/dev/null
    pkill -u "$uid" -x ControlStrip 2>/dev/null || true
fi
echo "Removed Headless. The built-in display stays disabled until restart or 'Headless headless off'."
