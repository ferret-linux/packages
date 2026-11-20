#!/usr/bin/env bash
# Shared RPM filename sanitizer — used by --print-nvr probes and by the
# workflow's sanitize step so both sides always agree on asset names.

sanitize_rpm_name() {
    printf '%s' "$1" \
        | sed 's/^[0-9]*://' \
        | sed 's/-[0-9]*:/-/' \
        | sed 's/\^/-/g'
}
