#!/bin/bash
set -e

# Ensure openclaw is in the process-compose file list
PC_LIST="/etc/sandbox/process-compose-files.txt"
OC_YAML="/etc/sandbox/config/process-compose.openclaw.yaml"

if [ -f "$PC_LIST" ]; then
  if ! grep -qF "$OC_YAML" "$PC_LIST"; then
    echo "$OC_YAML" >> "$PC_LIST"
  fi
else
  # File doesn't exist — create with openclaw entry;
  # entrypoint.sh will add the base entries or use its fallback.
  echo "$OC_YAML" > "$PC_LIST"
fi

exec /usr/local/bin/entrypoint.sh "$@"
