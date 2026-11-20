#!/usr/bin/env bash
# Resolve the mise NVR that the current upstream COPR source RPM would produce.
set -euo pipefail

NAME=mise
RELEASE=1.mink

API='https://copr.fedorainfracloud.org/api_3/build/list/?ownername=jdxcode&projectname=mise'

VERSION="$(curl -fsSL "$API" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
for item in data.get("items", []):
    if item.get("state") != "succeeded":
        continue
    source = item.get("source_package") or {}
    version = source.get("version")
    if version:
        print(version)
        break
')"
[[ -n "$VERSION" ]] || { echo "Failed to detect mise version from COPR" >&2; exit 1; }

# Copr reports source_package.version as "<upstream>-<release>" (e.g.
# 2026.11.11-1). Our RPM replaces that release with our mink marker.
VERSION="${VERSION%-*}"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "${NAME}-${VERSION}-${RELEASE}"
fi
