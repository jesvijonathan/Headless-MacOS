#!/bin/zsh
# Installs Headless system-wide:
#   /Applications/Headless.app                    (root-owned)
#   /Library/LaunchAgents/dev.jesvi.headless.plist (LoginWindow + Aqua sessions)
#   /Library/PrivilegedHelperTools/dev.jesvi.headless.fand + LaunchDaemon (fan control, from boot)
# Usage: sudo scripts/install.sh
set -eu
[[ $EUID == 0 ]] || exec sudo "$0" "$@"
user=${SUDO_USER:?run this with sudo from your own account}
uid=$(id -u "$user")
home=$(dscl . -read "/Users/$user" NFSHomeDirectory | awk '{print $2}')
root=${0:A:h:h}
app=/Applications/Headless.app
plist=/Library/LaunchAgents/dev.jesvi.headless.plist
settings="$home/Library/Application Support/Headless/settings.plist"

[[ -x "$root/build/Headless.app/Contents/MacOS/Headless" && -x "$root/build/headless-fand" ]] ||
    sudo -u "$user" "$root/scripts/build.sh"

launchctl bootout "gui/$uid/dev.jesvi.headless" 2>/dev/null || true
pkill -u "$uid" -f 'Headless.app/Contents/MacOS/Headless' 2>/dev/null || true

# Root-owned: it also loads at the login window, so it must not be user-writable.
rm -rf "$app"
ditto "$root/build/Headless.app" "$app"
chown -R root:wheel "$app"
chmod -R go-w "$app"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.jesvi.headless</string>
<key>ProgramArguments</key><array><string>$app/Contents/MacOS/Headless</string></array>
<key>EnvironmentVariables</key><dict>
    <key>HEADLESS_SETTINGS</key><string>$settings</string>
</dict>
<key>LimitLoadToSessionType</key><array><string>LoginWindow</string><string>Aqua</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
chown root:wheel "$plist"
chmod 644 "$plist"
plutil -lint "$plist" >/dev/null

launchctl bootstrap "gui/$uid" "$plist"

# Fan daemon (root). Stopping it hands the fans back to macOS.
fand=/Library/PrivilegedHelperTools/dev.jesvi.headless.fand
daemon=/Library/LaunchDaemons/dev.jesvi.headless.fand.plist
launchctl bootout system/dev.jesvi.headless.fand 2>/dev/null || true
install -o root -g wheel -m 755 "$root/build/headless-fand" "$fand"
cat > "$daemon" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.jesvi.headless.fand</string>
<key>ProgramArguments</key><array><string>$fand</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
PLIST
chown root:wheel "$daemon"
chmod 644 "$daemon"
plutil -lint "$daemon" >/dev/null
launchctl bootstrap system "$daemon"

echo "Installed $app, $plist and the fan daemon."
echo "If another fan tool (e.g. Macs Fan Control) is running, quit it or set it to Auto - two controllers will fight."
