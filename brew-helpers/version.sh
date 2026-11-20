#!/usr/bin/env bash
# Single source of truth for the brew-helpers NVR.
set -euo pipefail

NAME=brew-helpers
VERSION=1.0
RELEASE=1.mink

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "${NAME}-${VERSION}-${RELEASE}"
fi
