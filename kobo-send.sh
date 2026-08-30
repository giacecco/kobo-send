#!/bin/bash
# kobo-send.sh — convert file(s) to KEPUB and upload to a Google Drive folder
# that KoboCloud syncs to the Kobo Clara 2E.
#
# Pipeline:  input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive
# Already-epub input skips pandoc. PDF input is first turned into Markdown by
# `claude -p` (pandoc can't read PDF), then rejoins the normal pandoc step.
# Accepts one or more files (loops over all).
#
# URL input (send a web page, not a file) is NOT currently supported — it was
# removed pending a rework of that branch (unreliable claude -p WebFetch
# behaviour, never confirmed fully working). See git history if reviving it.
#
# Usage:  kobo-send.sh /path/to/file.md [more files...]

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

# claude -p (PDF/URL conversion) authenticates via an API key rather than an
# interactive OAuth login — the OAuth session expired once already and
# silently broke every conversion until manually re-run through `claude
# login`. An API key doesn't expire the same way. Billed separately, at
# Anthropic API rates, from any Claude subscription.
ANTHROPIC_KEY_FILE="$HOME/.config/kobo-send/anthropic-api-key"
if [ -f "$ANTHROPIC_KEY_FILE" ]; then
  ANTHROPIC_API_KEY="$(cat "$ANTHROPIC_KEY_FILE")"
  export ANTHROPIC_API_KEY
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

# The webhook can fire off several kobo-send.sh runs back to back (e.g. a
# multi-file Share Sheet send), and a manual CLI run could overlap one of
# those too. Serialize with a flock so only one conversion runs system-wide
# at a time — concurrent claude -p / rclone / pandoc invocations queue up
# and wait rather than racing each other. flock blocks until the lock is
# free, so this doesn't fail an overlapping run, just delays it.
LOCKFILE="${TMPDIR:-/tmp}/kobo-send.lock"
exec 200>"$LOCKFILE"
flock 200

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
  KEPUB=""
  # Reset per-iteration — the pdf case below only conditionally sets this,
  # and without a reset a byline found for one input could leak into the
  # metadata of the next input that doesn't have one.
  AUTHOR=""

  # URL input isn't supported (see the file header) — reject it cleanly
  # rather than trying to treat it as a filesystem path.
  if [[ "$INPUT" =~ ^https?:// ]]; then
    notify "Unsupported" "URL input is not supported: $INPUT"
    failed=$((failed+1))
    continue
  fi
  if [ ! -f "$INPUT" ]; then
    notify "Skipped" "Not a file: $(basename "$INPUT")"
    failed=$((failed+1))
    continue
  fi

  BASENAME="$(basename "$INPUT")"
  # A .kepub.epub is already in its final form — and kepubify rejects it
  # outright ('invalid extension ".kepub.epub"') — so it must bypass both
  # conversion steps, not be fed back through them.
  if [[ "$(printf '%s' "$BASENAME" | tr '[:upper:]' '[:lower:]')" == *.kepub.epub ]]; then
    EXT_LC="kepub.epub"
    TITLE="${BASENAME%.*.*}"
  else
    EXT_LC="$(printf '%s' "${BASENAME##*.}" | tr '[:upper:]' '[:lower:]')"
    TITLE="${BASENAME%.*}"
  fi
  # Sanitize for use as a filename — an input filename can come from
  # anywhere (e.g. a Share Sheet turning a shared link into a "file" whose
  # name is the raw URL), so don't trust it to be filesystem/Drive-friendly.
  # STEM is for the filename only; TITLE (unsanitized) is for the book's
  # displayed title — tr's conversion of stray punctuation to "_" has no
  # business leaking into that.
  STEM="$(printf '%s' "$TITLE" | tr -c '[:alnum:] ._-' '_' | cut -c1-80)"
  [ -z "$STEM" ] && STEM="file"
  [ -z "$TITLE" ] && TITLE="$STEM"
  EPUB="$WORKDIR/$STEM.epub"

  # --- Step 1: get an epub -------------------------------------------------
  case "$EXT_LC" in
    pdf)
      # pandoc can't read PDF, so use claude -p to extract the content as
      # Markdown first, then fall through the normal pandoc conversion.
      MD="$WORKDIR/$STEM.md"
      if ! claude --allowedTools "Read" -p "Convert the PDF at $INPUT into clean Markdown, starting with a single top-level '# Title' heading taken from the document's actual title (not its filename). If the document states one or more author names, add a single line immediately after the title heading, formatted exactly as '_by Author Name_' (or '_by Author One, Author Two_' for multiple authors) — omit this line entirely if no author is stated in the document; never guess or write 'Unknown'. Preserve headings, paragraphs, and lists faithfully. Strip anything that isn't the article/document's own content: adverts, subscription/paywall prompts, navigation links, page headers and footers, page numbers, and repeated boilerplate. This conversion is for the requester's own personal, offline reading on a device they own, of a document they already possess — it is not for redistribution or republishing. If you are unable to read or convert the document for any reason — blocked, unreadable, no extractable content, or anything else — do not explain why and do not output partial or invented content: output only the exact single line CONVERSION_FAILED and nothing else. Otherwise output ONLY the Markdown content — no commentary, no code fences, no preamble." > "$MD" 2>"$WORKDIR/claude.err"; then
        notify "Conversion failed" "claude could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      if [ ! -s "$MD" ]; then
        notify "Conversion failed" "claude produced no content for $BASENAME"
        failed=$((failed+1))
        continue
      fi
      # Same sentinel + refusal-guards as the URL branch — see comments there.
      if grep -q '^CONVERSION_FAILED$' "$MD"; then
        notify "Conversion failed" "claude declined or could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      if [ "$(wc -c < "$MD")" -lt 300 ]; then
        notify "Conversion failed" "claude declined or found no content in $BASENAME"
        failed=$((failed+1))
        continue
      fi
      if [ "$(grep -c -E '\S' "$MD")" -lt 8 ]; then
        notify "Conversion failed" "claude returned unexpected output for $BASENAME"
        failed=$((failed+1))
        continue
      fi
      # Prefer the document's own title over the input filename — PDFs
      # exported by an app (e.g. macOS's generic "PDF document.pdf" from
      # Safari's Print > Save as PDF) often carry no meaningful filename at
      # all. Same first-non-blank-line extraction as the URL branch, falling
      # back to the filename-derived TITLE/STEM already set above if
      # extraction yields nothing. Keep TITLE unsanitized (see URL branch
      # note above) — only STEM gets mangled for use as a filename.
      PDF_TITLE="$(grep -m1 -E '\S' "$MD" | sed -E 's/^[#*_ ]+//; s/[#*_ ]+$//')" || true
      if [ -n "$PDF_TITLE" ]; then
        TITLE="$PDF_TITLE"
        STEM="$(printf '%s' "$PDF_TITLE" | tr -c '[:alnum:] ._-' '_' | cut -c1-80)"
        [ -z "$STEM" ] && STEM="file"
      fi
      # Same byline extraction as the URL branch — see comment there.
      AUTHOR="$(grep -m2 -E '\S' "$MD" | tail -n1 | sed -nE 's/^[_*]*[Bb]y[[:space:]]+(.+[^_*[:space:]])[_*]*[[:space:]]*$/\1/p')" || true
      EPUB="$WORKDIR/$STEM.epub"
      PANDOC_META=(--metadata title="$TITLE" --epub-title-page=false)
      [ -n "$AUTHOR" ] && PANDOC_META+=(--metadata author="$AUTHOR")
      if ! pandoc "$MD" -o "$EPUB" "${PANDOC_META[@]}" 2>"$WORKDIR/pandoc.err"; then
        notify "Conversion failed" "pandoc could not convert $BASENAME"
        failed=$((failed+1))
        continue
      fi
      ;;
    epub)
      cp "$INPUT" "$EPUB"
      ;;
    kepub.epub)
      # Already converted — nothing for pandoc or kepubify to do; setting
      # KEPUB here makes Step 2 skip itself and go straight to the upload.
      KEPUB="$WORKDIR/$STEM.kepub.epub"
      cp "$INPUT" "$KEPUB"
      ;;
    md|markdown|txt|html|htm|docx|rtf|fb2|org|tex|rst)
      # --metadata title gives the book a sensible title on the Kobo shelf;
      # --epub-title-page=false skips the standalone title-only front page.
      if ! pandoc "$INPUT" -o "$EPUB" --metadata title="$TITLE" --epub-title-page=false 2>"$WORKDIR/pandoc.err"; then
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
  # Skipped when the input was already a .kepub.epub (KEPUB set above).
  # kepubify -o DIR writes <stem>[_converted].kepub.epub into DIR (the exact
  # suffix has varied across kepubify versions), so glob for it rather than
  # hardcoding the name.
  if [ -z "$KEPUB" ]; then
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
