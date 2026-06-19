#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="${1:-com.local.aprilai}"

echo "Resetting macOS privacy permissions for $BUNDLE_ID"

for service in Accessibility Microphone ScreenCapture AppleEvents; do
  if /usr/bin/tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  reset $service"
  else
    echo "  could not reset $service (it may not exist yet)"
  fi
done

echo "Done. Reopen April AI and grant permissions again from Settings."
