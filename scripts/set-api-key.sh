#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 sk-..."
  exit 1
fi

if [[ "$1" != sk-* || "$1" =~ [[:space:]] ]]; then
  echo "Error: expected an OpenAI API key that starts with sk-."
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
TMP_FILE="$(mktemp)"

escaped_key="${1//\\/\\\\}"
escaped_key="${escaped_key//\"/\\\"}"

if [[ -f "$ENV_FILE" ]]; then
  awk -v key="$escaped_key" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY[[:space:]]*=/ {
      print "OPENAI_API_KEY=\"" key "\""
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "OPENAI_API_KEY=\"" key "\""
      }
    }
  ' "$ENV_FILE" > "$TMP_FILE"
else
  printf 'OPENAI_API_KEY="%s"\n' "$escaped_key" > "$TMP_FILE"
fi

mv "$TMP_FILE" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "Saved OpenAI API key to $ENV_FILE."
