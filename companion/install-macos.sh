#!/usr/bin/env bash
#
# Install (or uninstall) the CrabulikConsole layout-indicator companion as a
# macOS LaunchAgent, so it runs continuously and starts automatically at login.
#
# What it does:
#   - creates a Python virtualenv in companion/.venv (reused if present)
#   - installs the macOS dependencies (requirements-macos.txt)
#   - writes ~/Library/LaunchAgents/com.crabulik.indicator.plist
#   - loads the agent (RunAtLoad + KeepAlive) and starts it now
#
# Usage:
#   ./install-macos.sh              install and start the companion
#   ./install-macos.sh --uninstall  stop and remove the LaunchAgent
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
DOMAIN="gui/$(id -u)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Install (or uninstall) the CrabulikConsole layout-indicator companion as a
macOS LaunchAgent, so it runs continuously and starts automatically at login.

What it does:
  - creates a Python virtualenv in companion/.venv (reused if present)
  - installs the macOS dependencies (requirements-macos.txt)
  - writes ~/Library/LaunchAgents/com.crabulik.indicator.plist
  - loads the agent (RunAtLoad + KeepAlive) and starts it now

Usage:
  ./install-macos.sh              install and start the companion
  ./install-macos.sh --uninstall  stop and remove the LaunchAgent
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
  if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    info "Removed $PLIST"
  else
    info "No LaunchAgent plist found (nothing to remove)."
  fi
  info "Done. The virtualenv ($VENV_DIR) and logs were left in place."
}

install() {
  require_macos

  command -v python3 >/dev/null 2>&1 || {
    err "python3 not found. Install Python 3.10+ and retry."
    exit 1
  }

  if [[ ! -x "$VENV_PY" ]]; then
    info "Creating virtualenv at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
  else
    info "Reusing existing virtualenv at $VENV_DIR"
  fi

  info "Installing dependencies (requirements-macos.txt) ..."
  "$VENV_PY" -m pip install --quiet --upgrade pip || true
  "$VENV_PY" -m pip install --quiet -r "$COMPANION_DIR/requirements-macos.txt"

  info "Writing LaunchAgent plist -> $PLIST"
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$VENV_PY</string>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
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

  info "Installed. The companion now runs continuously and starts at login."
  echo
  echo "  Logs:    $LOG"
  echo "  Status:  launchctl print $DOMAIN/$LABEL | grep -E 'state|pid'"
  echo "  Remove:  $0 --uninstall"
  echo
  warn "macOS attributes Bluetooth permission to the binary launchd runs:"
  warn "  $VENV_PY"
  warn "If the LEDs don't update, grant it Bluetooth under"
  warn "  System Settings > Privacy & Security > Bluetooth"
  warn "then re-run this script. Tip: run it once in Terminal first to confirm —"
  warn "  $VENV_PY $SCRIPT"
}

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  --help|-h)      usage ;;
  "")             install ;;
  *)              err "Unknown option: $1"; echo; usage; exit 1 ;;
esac
