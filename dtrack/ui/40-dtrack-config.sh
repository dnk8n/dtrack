#!/bin/sh
# Write /config.js from the container's environment, so one published image
# serves any tenant and host (see dtrack/ui/src/config.ts). nginx's official
# entrypoint runs this before starting nginx.
#
# Images built with RUNTIME_CONFIG=true carry no baked-in settings, so the
# four connection settings are required: refuse to start without them.
set -eu

html=/usr/share/nginx/html
out="$html/config.js"

if [ -f "$html/.runtime-config" ]; then
    missing=""
    for var in MSAL_CLIENT_ID MSAL_AUTHORITY APP_BASE_URI API_BASE_URI; do
        eval "val=\${$var:-}"
        [ -n "$val" ] || missing="$missing $var"
    done
    if [ -n "$missing" ]; then
        echo "40-dtrack-config: missing required environment:$missing" >&2
        exit 1
    fi
fi

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

{
    printf '// Generated at container start by 40-dtrack-config.sh\n'
    printf 'window.__DTRACK_CONFIG__ = {'
    sep=""
    for var in MSAL_CLIENT_ID MSAL_AUTHORITY APP_BASE_URI API_BASE_URI PALETTE_PRIMARY PALETTE_SECONDARY; do
        eval "val=\${$var:-}"
        if [ -n "$val" ]; then
            printf '%s"%s": "%s"' "$sep" "$var" "$(json_escape "$val")"
            sep=", "
        fi
    done
    printf '};\n'
} > "$out"
echo "40-dtrack-config: wrote $out"
