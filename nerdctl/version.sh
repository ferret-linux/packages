#!/usr/bin/env bash
# Resolve the nerdctl NVR that the current upstream release would produce.
set -euo pipefail

NAME=nerdctl
RELEASE=1.mink

CURL_AUTH=()
[[ -n "${GITHUB_TOKEN:-}" ]] && CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

TAG="$(curl -fsSL "${CURL_AUTH[@]}" \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/containerd/nerdctl/releases/latest \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)"
[[ -n "$TAG" ]] || { echo "Failed to detect nerdctl release tag" >&2; exit 1; }

VERSION="${TAG#v}"
[[ -n "$VERSION" && "$VERSION" != "$TAG" ]] \
    || { echo "Unexpected nerdctl tag format: $TAG" >&2; exit 1; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "${NAME}-${VERSION}-${RELEASE}"
fi
