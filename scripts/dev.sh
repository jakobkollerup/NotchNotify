#!/usr/bin/env bash
# Build a debug app. Run it after quitting the previous instance.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION=debug bash scripts/build-notch.sh
printf 'Open build/NotchNotify.app after quitting the previous instance.\n'
