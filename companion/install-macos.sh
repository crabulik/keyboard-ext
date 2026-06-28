#!/usr/bin/env bash
#
# Install (or uninstall) the CrabulikConsole layout-indicator companion as a
# macOS LaunchAgent, so it runs continuously and starts automatically at login.
#
# Why this is more than a plist: macOS attributes Bluetooth permission to the
# running executable's app bundle. A bare framework `python3` has no
# NSBluetoothAlwaysUsageDescription in its Info.plist, so under launchd the OS
# *hard-crashes* the process (TCC) the instant it touches CoreBluetooth — it
# only "works" from Terminal because it borrows Terminal's permission. So this
# script builds a tiny .app wrapper around the interpreter whose Info.plist
# declares the Bluetooth usage, and points the LaunchAgent at that.
#
# What it does:
#   - creates a Python virtualenv in companion/.venv (reused if present)
#   - installs the macOS dependencies (requirements-macos.txt)
#   - builds ~/Library/Application Support/CrabulikConsole/CrabulikIndicator.app
#     (a copy of the framework python stub + our Info.plist, ad-hoc signed)
#   - writes ~/Library/LaunchAgents/com.crabulik.indicator.plist and loads it
#
# Usage:
#   ./install-macos.sh              install and start the companion
#   ./install-macos.sh --uninstall  stop and remove the LaunchAgent + app
#   ./install-macos.sh --help       show this help
#
set -euo pipefail

LABEL="com.crabulik.indicator"
COMPANION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$COMPANION_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python3"
SCRIPT="$COMPANION_DIR/crabulik_indicator.py"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/crabulik-indicator.log"
APP_SUPPORT="$HOME/Library/Application Support/CrabulikConsole"
APP="$APP_SUPPORT/CrabulikIndicator.app"
RUNNER="$APP/Contents/MacOS/runner"
DOMAIN="gui/$(id -u)"
BT_USAGE="CrabulikConsole shows your active keyboard layout on the device's LEDs over Bluetooth."

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Install (or uninstall) the CrabulikConsole layout-indicator companion as a
macOS LaunchAgent, so it runs continuously and starts automatically at login.

It builds a small .app wrapper around the Python interpreter whose Info.plist
declares NSBluetoothAlwaysUsageDescription, because macOS otherwise crashes a
bare python that touches Bluetooth under launchd.

Usage:
  ./install-macos.sh              install and start the companion
  ./install-macos.sh --uninstall  stop and remove the LaunchAgent + app
  ./install-macos.sh --help       show this help
EOF
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    err "This installer is for macOS only."
    exit 1
  fi
}

uninstall() {
  require_macos
  info "Stopping and removing the LaunchAgent ($LABEL)..."
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  [[ -f "$PLIST" ]] && { rm -f "$PLIST"; info "Removed $PLIST"; }
  [[ -d "$APP" ]]   && { rm -rf "$APP"; info "Removed $APP"; }
  info "Done. The virtualenv ($VENV_DIR) and logs were left in place."
}

# Build the .app wrapper: a copy of the framework python stub with our Info.plist
# (so NSBundle.mainBundle carries the Bluetooth usage string), ad-hoc signed.
build_app() {
  local base_prefix stub stubdir old_dep rel dylib
  base_prefix="$("$VENV_PY" -c 'import sys; print(sys.base_prefix)')"
  stub="$base_prefix/Resources/Python.app/Contents/MacOS/Python"
  if [[ ! -x "$stub" ]]; then
    err "Could not find the framework python stub at:"
    err "  $stub"
    err "This installer needs a macOS framework build of Python (the default"
    err "Xcode / python.org / Homebrew pythons qualify)."
    exit 1
  fi
  stubdir="$(dirname "$stub")"
  # The stub loads the framework dylib via a relocatable path; rewrite it to an
  # absolute path so the copy works outside the framework.
  old_dep="$(otool -L "$stub" | awk '{gsub(/^[ \t]+/,"")} $1 ~ /^@(executable_path|loader_path|rpath)/ && $1 ~ /\/Python[0-9]*$/ {print $1; exit}')"
  rel="${old_dep#@executable_path/}"
  dylib="$("$VENV_PY" -c 'import os,sys; print(os.path.realpath(os.path.join(sys.argv[1], sys.argv[2])))' "$stubdir" "$rel")"
  [[ -f "$dylib" ]] || dylib="$base_prefix/Python3"

  info "Building app wrapper -> $APP"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>          <string>$LABEL</string>
  <key>CFBundleName</key>                <string>CrabulikIndicator</string>
  <key>CFBundleDisplayName</key>         <string>CrabulikConsole Layout Indicator</string>
  <key>CFBundleExecutable</key>          <string>runner</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key>  <string>1.0</string>
  <key>CFBundleVersion</key>             <string>1</string>
  <key>LSUIElement</key>                 <true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>$BT_USAGE</string>
</dict>
</plist>
PLISTEOF

  cp "$stub" "$RUNNER"
  chmod u+w "$RUNNER"
  [[ -n "$old_dep" ]] && install_name_tool -change "$old_dep" "$dylib" "$RUNNER" 2>/dev/null || true
  codesign -s - --force "$APP" >/dev/null 2>&1 || codesign -s - --force "$RUNNER" >/dev/null 2>&1

  # Stash what the LaunchAgent needs to run this interpreter against our venv.
  PY_HOME="$base_prefix"
  PY_PATH="$("$VENV_PY" -c 'import sys,os; print(os.path.join(sys.prefix,"lib","python%d.%d"%sys.version_info[:2],"site-packages"))')"
}

install() {
  require_macos
  command -v python3 >/dev/null 2>&1 || { err "python3 not found. Install Python 3.10+ and retry."; exit 1; }

  if [[ ! -x "$VENV_PY" ]]; then
    info "Creating virtualenv at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
  else
    info "Reusing existing virtualenv at $VENV_DIR"
  fi

  info "Installing dependencies (requirements-macos.txt) ..."
  "$VENV_PY" -m pip install --quiet --upgrade pip || true
  "$VENV_PY" -m pip install --quiet -r "$COMPANION_DIR/requirements-macos.txt"

  mkdir -p "$APP_SUPPORT" "$(dirname "$PLIST")" "$(dirname "$LOG")"
  build_app  # sets PY_HOME and PY_PATH

  info "Writing LaunchAgent plist -> $PLIST"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER</string>
    <string>$SCRIPT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PYTHONHOME</key> <string>$PY_HOME</string>
    <key>PYTHONPATH</key> <string>$PY_PATH</string>
  </dict>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>ThrottleInterval</key>  <integer>30</integer>
  <key>StandardOutPath</key>   <string>$LOG</string>
  <key>StandardErrorPath</key> <string>$LOG</string>
</dict>
</plist>
PLISTEOF

  plutil -lint "$PLIST" >/dev/null

  info "Loading the agent ..."
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

  info "Installed. The companion runs continuously and starts at login."
  echo
  echo "  App:     $APP"
  echo "  Logs:    $LOG"
  echo "  Status:  launchctl print $DOMAIN/$LABEL | grep -E 'state|pid'"
  echo "  Remove:  $0 --uninstall"
  echo
  warn "First start: macOS should prompt to allow Bluetooth for \"CrabulikIndicator\"."
  warn "Click Allow. If you see no prompt and the LEDs don't update, enable"
  warn "  \"CrabulikIndicator\"  under  System Settings > Privacy & Security > Bluetooth"
  warn "and then: launchctl kickstart -k $DOMAIN/$LABEL"
  warn "Watch progress with:  tail -f \"$LOG\""
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  --help|-h)      usage ;;
  "")             install ;;
  *)              err "Unknown option: $1"; echo; usage; exit 1 ;;
esac
