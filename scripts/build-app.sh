#!/usr/bin/env bash
# Compatibility entry point for building NotchNotify.
set -euo pipefail
exec bash "$(dirname "$0")/build-notch.sh" "$@"
