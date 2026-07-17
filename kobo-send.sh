#!/bin/bash
# kobo-send.sh — convert file(s) to KEPUB and upload to a Google Drive folder
# that KoboCloud syncs to the Kobo Clara 2E.
#
# Pipeline:  input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive
# Already-epub input skips pandoc. PDF input and http(s) URLs are first turned
# into Markdown by `claude -p` (pandoc can read neither), then rejoin the
# normal pandoc step. Accepts one or more files/URLs (loops over all).
#
# Usage:  kobo-send.sh /path/to/file.md [more files or URLs...]

set -euo pipefail

# ------------------------------------------------------------------ config ---
# Actual values live in ~/.config/kobo-send/config (untracked, machine-
# specific) — see kobo-send.conf.example for the format. Defaults below are
# placeholders only.
GDRIVE_REMOTE="kobocloud"        # your rclone remote name
GDRIVE_FOLDER_ID=""              # the target Drive folder ID
PURGE_OLDER_THAN="3d"            # age at which old sends are purged from Drive

CONFIG_FILE="$HOME/.config/kobo-send/config"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
# -----------------------------------------------------------------------------

# Runs both on macOS (via Automator/Quick Actions, which use a minimal PATH)
# and on Linux (headless, via the webhook service) — set PATH and notify()
# for whichever this is.
if [[ "$(uname)" == "Darwin" ]]; then
  # Homebrew bins for both Apple Silicon (/opt/homebrew) and Intel
  # (/usr/local), plus ~/.local/bin where the claude CLI lives.
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.bin:$PATH"
  notify() {
    # notify "Title line" "message"
    osascript -e "display notification \"$2\" with title \"Kobo Send\" subtitle \"$1\"" >/dev/null 2>&1 || true
  }
else
  export PATH="$HOME/.local/bin:$HOME/.bin:$PATH"
  notify() {
    # notify "Title line" "message" — no GUI on a headless server, so just log.
    logger -t kobo-send "$1: $2" 2>/dev/null || true
    echo "$1: $2" >&2
  }
fi

# Verify tools exist up front with a clear message rather than a cryptic failure.
for tool in pandoc kepubify rclone claude; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    notify "Missing tool" "$tool not found — run: brew install $tool"
    echo "ERROR: $tool not found on PATH" >&2
    exit 1
  fi
done

if [ "$#" -eq 0 ]; then
  notify "Nothing to do" "No file was passed in"
  exit 1
fi

if [ -z "$GDRIVE_FOLDER_ID" ]; then
  notify "Not configured" "Set GDRIVE_FOLDER_ID in $CONFIG_FILE"
  echo "ERROR: GDRIVE_FOLDER_ID is not set — create $CONFIG_FILE (see kobo-send.conf.example)" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# KoboCloud has no "delete from Drive after sync" feature, and there's no way
# from the Mac side to confirm the Kobo has pulled a given file. Instead,
# purge anything older than PURGE_OLDER_THAN before each send — by then it
# will have synced over WiFi, and this also keeps the folder lean.
rclone delete "${GDRIVE_REMOTE}:" --drive-root-folder-id "$GDRIVE_FOLDER_ID" \
      --min-age "$PURGE_OLDER_THAN" >/dev/null 2>&1 || true

sent=0
failed=0

for INPUT in "$@"; do
  if [[ "$INPUT" =~ ^https?:// ]]; then
    IS_URL=1
  else
    IS_URL=0
    if [ ! -f "$INPUT" ]; then
      notify "Skipped" "Not a file: $(basename "$INPUT")"
      failed=$((failed+1))
      continue
    fi
  fi

  if [ "$IS_URL" -eq 1 ]; then
    # --- Step 1 (URL): fetch the page and extract it as Markdown -----------
    # pandoc has no web-page reader either, so use claude -p with WebFetch to
    # pull the article text, stripped of ads/nav/boilerplate, as Markdown.
    BASENAME="$INPUT"
    MD="$(mktemp "$WORKDIR/webpage.XXXXXX.md")"
    if ! claude --allowedTools "WebFetch" -p "Fetch the webpage at $INPUT and convert its main article content into clean Markdown, starting with a single top-level '# Title' heading taken from the page's actual title. Preserve headings, paragraphs, and lists faithfully. Strip anything that isn't the article's own content: adverts, subscription/paywall prompts, navigation links, cookie banners, related-article widgets, comment sections, and other boilerplate. This extraction is for the requester's own personal, offline reading on a device they own, of content they are already entitled to access (e.g. via an active subscription) — it is not for redistribution or republishing. That is legitimate personal format-shifting, comparable to a read-it-later service (Pocket, Instapaper) saving a paid article for its subscriber; do not decline on copyright grounds on that basis alone. Output ONLY the Markdown content — no commentary, no code fences, no preamble." > "$MD" 2>"$WORKDIR/claude.err"; then
      notify "Fetch failed" "claude could not fetch $INPUT"
      failed=$((failed+1))
      continue
    fi
    if [ ! -s "$MD" ]; then
      notify "Fetch failed" "claude produced no content for $INPUT"
      failed=$((failed+1))
      continue
    fi
    # claude sometimes refuses (e.g. over copyright concerns) and writes a
    # short refusal sentence to $MD instead of erroring out — a real article
    # is always far longer than that, so treat suspiciously short output as
    # a failure rather than converting the refusal itself into a "book".
    if [ "$(wc -c < "$MD")" -lt 300 ]; then
      notify "Fetch failed" "claude declined or found no article at $INPUT"
      failed=$((failed+1))
      continue
    fi
    # claude's WebFetch output doesn't reliably start with an exact "# Title"
    # heading, so take the first non-blank line and strip whatever markdown
    # decoration it has (#, *, _) rather than requiring that exact format.
    # The `|| true` matters: under set -e, grep finding no non-blank line at
    # all would otherwise kill the whole script instead of falling through to
    # the STEM="webpage" default below.
    STEM="$(grep -m1 -E '\S' "$MD" | sed -E 's/^[#*_ ]+//; s/[#*_ ]+$//' | tr -c '[:alnum:] ._-' '_' | cut -c1-80)" || true
    [ -z "$STEM" ] && STEM="webpage"
    EPUB="$WORKDIR/$STEM.epub"
    if ! pandoc "$MD" -o "$EPUB" --metadata title="$STEM" --epub-title-page=false 2>"$WORKDIR/pandoc.err"; then
      notify "Conversion failed" "pandoc could not convert $INPUT"
      failed=$((failed+1))
      continue
    fi
    EXT_LC=""
  else
    BASENAME="$(basename "$INPUT")"
    EXT_LC="$(printf '%s' "${BASENAME##*.}" | tr '[:upper:]' '[:lower:]')"
    # Sanitize like the URL branch does — an input filename can come from
    # anywhere (e.g. a Share Sheet turning a shared link into a "file" whose
    # name is the raw URL), so don't trust it to be filesystem/Drive-friendly.
    STEM="$(printf '%s' "${BASENAME%.*}" | tr -c '[:alnum:] ._-' '_' | cut -c1-80)"
    [ -z "$STEM" ] && STEM="file"
    EPUB="$WORKDIR/$STEM.epub"
  fi

  # --- Step 1: get an epub -------------------------------------------------
  case "$EXT_LC" in
    "")
      # URL input already produced $EPUB above; nothing more to do here.
      ;;
    pdf)
      # pandoc can't read PDF, so use claude -p to extract the content as
      # Markdown first, then fall through the normal pandoc conversion.
      MD="$WORKDIR/$STEM.md"
      if ! claude --allowedTools "Read" -p "Convert the PDF at $INPUT into clean Markdown. Preserve headings, paragraphs, and lists faithfully. Strip anything that isn't the article/document's own content: adverts, subscription/paywall prompts, navigation links, page headers and footers, page numbers, and repeated boilerplate. This conversion is for the requester's own personal, offline reading on a device they own, of a document they already possess — it is not for redistribution or republishing. Output ONLY the Markdown content — no commentary, no code fences, no preamble." > "$MD" 2>"$WORKDIR/claude.err"; then
        notify "Conversion failed" "claude could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      if [ ! -s "$MD" ]; then
        notify "Conversion failed" "claude produced no content for $BASENAME"
        failed=$((failed+1))
        continue
      fi
      # Same refusal-guard as the URL branch — see comment there.
      if [ "$(wc -c < "$MD")" -lt 300 ]; then
        notify "Conversion failed" "claude declined or found no content in $BASENAME"
        failed=$((failed+1))
        continue
      fi
      if ! pandoc "$MD" -o "$EPUB" --metadata title="$STEM" --epub-title-page=false 2>"$WORKDIR/pandoc.err"; then
        notify "Conversion failed" "pandoc could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      ;;
    epub)
      cp "$INPUT" "$EPUB"
      ;;
    md|markdown|txt|html|htm|docx|rtf|fb2|org|tex|rst)
      # --metadata title gives the book a sensible title on the Kobo shelf;
      # --epub-title-page=false skips the standalone title-only front page.
      if ! pandoc "$INPUT" -o "$EPUB" --metadata title="$STEM" --epub-title-page=false 2>"$WORKDIR/pandoc.err"; then
        notify "Conversion failed" "pandoc could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      ;;
    *)
      notify "Unsupported" ".$EXT_LC is not handled: $BASENAME"
      failed=$((failed+1))
      continue
      ;;
  esac

  # --- Step 2: epub -> kepub ----------------------------------------------
  # kepubify -o DIR writes <stem>[_converted].kepub.epub into DIR (the exact
  # suffix has varied across kepubify versions), so glob for it rather than
  # hardcoding the name.
  if ! kepubify --no-add-dummy-titlepage -o "$WORKDIR" "$EPUB" >/dev/null 2>&1; then
    notify "Conversion failed" "kepubify failed on $BASENAME"
    failed=$((failed+1))
    continue
  fi
  KEPUB="$(find "$WORKDIR" -maxdepth 1 -name "${STEM}*.kepub.epub" -print -quit)"
  if [ -z "$KEPUB" ] || [ ! -f "$KEPUB" ]; then
    notify "Conversion failed" "no kepub produced for $BASENAME"
    failed=$((failed+1))
    continue
  fi

  # --- Step 3: upload to the Google Drive folder ---------------------------
  # --drive-root-folder-id makes "remote:" resolve to that specific folder.
  if rclone copy "$KEPUB" "${GDRIVE_REMOTE}:" \
        --drive-root-folder-id "$GDRIVE_FOLDER_ID" 2>"$WORKDIR/rclone.err"; then
    sent=$((sent+1))
  else
    notify "Upload failed" "rclone could not upload $(basename "$KEPUB")"
    failed=$((failed+1))
    continue
  fi
done

# --- summary -----------------------------------------------------------------
if [ "$sent" -gt 0 ] && [ "$failed" -eq 0 ]; then
  notify "Done" "$sent file(s) sent to Kobo folder"
elif [ "$sent" -gt 0 ]; then
  notify "Partly done" "$sent sent, $failed failed"
else
  notify "Failed" "$failed file(s) failed"
  exit 1
fi
