#!/bin/bash
# kobo-send-client.sh — thin client for the kobo-send webhook.
#
# The actual pandoc/kepubify/rclone/claude pipeline runs on a server
# (see kobo-send.sh) behind a Cloudflare Tunnel. This script just posts a
# file or URL to that webhook and lets the server do the work — the same
# thing the iOS Shortcuts do. Kept as a Quick Action so Finder/right-click
# still works, without needing the pipeline's dependencies on this Mac.
#
# Usage:  kobo-send-client.sh /path/to/file.pdf [more files or URLs...]

set -euo pipefail

WEBHOOK_URL="https://kobo.yourdomain.com/send"  # set this to your own tunnel hostname
TOKEN_FILE="$HOME/.config/kobo-send/webhook-token"

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bin:$PATH"

notify() {
  # notify "Title line" "message"
  osascript -e "display notification \"$2\" with title \"Kobo Send\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

if [ ! -f "$TOKEN_FILE" ]; then
  notify "Not configured" "Missing $TOKEN_FILE"
  echo "ERROR: $TOKEN_FILE not found" >&2
  exit 1
fi
TOKEN="$(cat "$TOKEN_FILE")"

if [ "$#" -eq 0 ]; then
  notify "Nothing to do" "No file was passed in"
  exit 1
fi

queued=0
failed=0

for INPUT in "$@"; do
  if [[ "$INPUT" =~ ^https?:// ]]; then
    ESCAPED_URL="$(printf '%s' "$INPUT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK_URL" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"url\":\"$ESCAPED_URL\"}")" || HTTP_CODE="000"
    LABEL="$INPUT"
  else
    if [ ! -f "$INPUT" ]; then
      notify "Skipped" "Not a file: $(basename "$INPUT")"
      failed=$((failed+1))
      continue
    fi
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$WEBHOOK_URL" \
          -H "Authorization: Bearer $TOKEN" \
          -F "file=@$INPUT")" || HTTP_CODE="000"
    LABEL="$(basename "$INPUT")"
  fi

  if [ "$HTTP_CODE" = "202" ]; then
    queued=$((queued+1))
  else
    notify "Failed" "server returned $HTTP_CODE for $LABEL"
    failed=$((failed+1))
  fi
done

# --- summary -----------------------------------------------------------------
# The server queues jobs and processes them in the background (a claude -p
# fetch/PDF conversion can take minutes), so this can only confirm the
# request was accepted, not that the file has actually landed in Drive yet.
if [ "$queued" -gt 0 ] && [ "$failed" -eq 0 ]; then
  notify "Queued" "$queued file(s) sent to the Kobo pipeline"
elif [ "$queued" -gt 0 ]; then
  notify "Partly queued" "$queued queued, $failed failed"
else
  notify "Failed" "$failed file(s) failed"
  exit 1
fi
