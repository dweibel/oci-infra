#!/bin/bash
# Setup a GitHub Actions self-hosted runner on the OCI instance.
#
# This installs the runner as a systemd user service under the opc user.
# It survives reboots and runs without an active SSH session.
#
# Prerequisites:
#   1. Generate a runner registration token at:
#      https://github.com/dweibel/gocoder/settings/actions/runners/new
#
# Usage (from local machine):
#   ssh oci-agent 'bash -s' < scripts/setup-github-runner.sh <TOKEN>
#
# Usage (on the instance):
#   bash setup-github-runner.sh <TOKEN>
#
# To re-register after a server rebuild, generate a new token and re-run.

set -euo pipefail

TOKEN="${1:?Usage: $0 <GITHUB_RUNNER_REGISTRATION_TOKEN>}"
REPO_URL="${2:-https://github.com/dweibel/gocoder}"
RUNNER_NAME="${3:-oci-arm64}"
RUNNER_DIR="$HOME/actions-runner"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  x86_64)        RUNNER_ARCH="x64"   ;;
  *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "==> Setting up GitHub Actions runner (${RUNNER_ARCH}) for ${REPO_URL}..."

# Install dependencies (Oracle Linux / RHEL)
if command -v dnf &>/dev/null; then
  sudo dnf install -y libicu 2>/dev/null || true
elif command -v yum &>/dev/null; then
  sudo yum install -y libicu 2>/dev/null || true
fi

# Download latest runner
mkdir -p "$RUNNER_DIR" && cd "$RUNNER_DIR"
LATEST=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
  | grep -oP '"tag_name":\s*"v\K[^"]+')
TARBALL="actions-runner-linux-${RUNNER_ARCH}-${LATEST}.tar.gz"

echo "==> Downloading runner v${LATEST}..."
curl -sL "https://github.com/actions/runner/releases/download/v${LATEST}/${TARBALL}" -o "$TARBALL"
tar xzf "$TARBALL"
rm -f "$TARBALL"

# Stop existing service if running
systemctl --user stop actions-runner 2>/dev/null || true

# Configure (non-interactive, replace existing)
./config.sh \
  --url "$REPO_URL" \
  --token "$TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "self-hosted,linux,arm64" \
  --unattended \
  --replace

# Install as systemd user service
echo "==> Installing as systemd user service..."
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/actions-runner.service <<EOF
[Unit]
Description=GitHub Actions Runner (${RUNNER_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUNNER_DIR}
ExecStart=${RUNNER_DIR}/run.sh
Restart=always
RestartSec=5
Environment=RUNNER_ALLOW_RUNASROOT=0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable actions-runner
systemctl --user start actions-runner

# Enable lingering so the service runs without an active login session
loginctl enable-linger "$(whoami)"

echo ""
echo "==> Runner '${RUNNER_NAME}' installed and running!"
echo "    Status:  systemctl --user status actions-runner"
echo "    Logs:    journalctl --user -u actions-runner -f"
echo "    Stop:    systemctl --user stop actions-runner"
echo "    Remove:  cd ${RUNNER_DIR} && ./config.sh remove --token <TOKEN>"
