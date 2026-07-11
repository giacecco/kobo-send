# kobo-send

Send a file — or a web page URL — straight to a Kobo Clara 2E from macOS, via a Finder Quick Action or Safari's Share menu. No cable required.

## How it works

The Kobo has no native cloud sync, but [KoboCloud](https://github.com/fsantini/KoboCloud) can be installed on it to pull files from a shared Google Drive folder whenever it's on WiFi. `kobo-send.sh` prepares files for that folder:

```
input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive folder
```

- Markdown, plain text, HTML, DOCX, RTF, FB2, org, LaTeX and reStructuredText are converted to EPUB by [pandoc](https://pandoc.org).
- EPUB input is used as-is.
- PDF input and `http(s)://` URLs can't be read by pandoc, so they're first turned into clean Markdown by `claude -p` (the [Claude Code](https://claude.com/claude-code) CLI), stripping ads, navigation, cookie banners, and other boilerplate along the way — then the result rejoins the normal pandoc step.
- [kepubify](https://github.com/pgaskin/kepubify) converts the EPUB into Kobo's `.kepub.epub` format for reading-stats/page-turn support.
- [rclone](https://rclone.org) uploads the result to a specific Google Drive folder.
- Before each send, files older than a configurable age are purged from that Drive folder — KoboCloud has no "delete after sync" feature of its own, and there's no way to confirm from the Mac side that the Kobo has actually pulled a given file, so this is a time-based approximation.

## Requirements

- macOS
- [Homebrew](https://brew.sh)
- `brew install pandoc kepubify rclone`
- [Claude Code](https://claude.com/claude-code) CLI (`claude`) — used only for PDF and URL conversion
- A KoboCloud installation on the Kobo, watching a Google Drive folder (see KoboCloud's own docs for that setup)
- An rclone remote configured for that Google Drive folder: `rclone config`

## Setup

1. Install the dependencies above.
2. Copy `kobo-send.conf.example` to `~/.config/kobo-send/config` and fill in your rclone remote name and Drive folder ID:
   ```
   mkdir -p ~/.config/kobo-send
   cp kobo-send.conf.example ~/.config/kobo-send/config
   $EDITOR ~/.config/kobo-send/config
   ```
3. Install the script:
   ```
   mkdir -p ~/.bin
   cp kobo-send.sh ~/.bin/kobo-send.sh
   chmod +x ~/.bin/kobo-send.sh
   ```
4. Set up the Finder Quick Action and/or Safari "Send Page to Kobo" Service (see `automator/`) so both call `~/.bin/kobo-send.sh`.
5. In System Settings → General → Login Items & Extensions, enable the new Quick Action/Service — they're often off by default.

## Usage

From Finder, right-click one or more files → Quick Actions → **Send to Kobo**.

From Safari, use Share (or the Services menu) → **Send Page to Kobo** to send the current page.

Or run it directly:

```
kobo-send.sh ~/Documents/report.pdf
kobo-send.sh https://example.com/some-article
kobo-send.sh file1.md file2.epub https://example.com/another-article
```

## Known limitations

- PDF and web-page conversion quality depends on `claude -p`'s extraction — it's generally good for article-shaped content, less reliable for complex multi-column layouts or heavily scripted pages.
- The Drive-folder purge is time-based, not sync-confirmed — set `PURGE_OLDER_THAN` generously if your Kobo doesn't connect to WiFi often.
