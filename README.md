# kobo-send

Send a file — or a web page URL — straight to a Kobo Clara 2E from macOS or iOS, via a macOS Shortcut (Finder's Share menu or Safari's Share menu) or an iOS Shortcut. No cable required.

## How it works

The Kobo has no native cloud sync, but [KoboCloud](https://github.com/fsantini/KoboCloud) can be installed on it to pull files from a shared Google Drive folder whenever it's on WiFi.

The actual conversion pipeline runs on an always-on Linux server, reachable over a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — the Mac and any iPhone just post a file or URL to it and don't need any of the pipeline's dependencies installed locally:

```
Mac Shortcut ──────┐
iOS Shortcut ──────┼──> kobo-webhook (Bun/TS) ──> kobo-send.sh:
Safari Share ──────┘      on the server            input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive folder
```

Inside `kobo-send.sh`:

- Markdown, plain text, HTML, DOCX, RTF, FB2, org, LaTeX and reStructuredText are converted to EPUB by [pandoc](https://pandoc.org).
- EPUB input is used as-is.
- PDF input and `http(s)://` URLs can't be read by pandoc, so they're first turned into clean Markdown by `claude -p` (the [Claude Code](https://claude.com/claude-code) CLI), stripping ads, navigation, cookie banners, and other boilerplate along the way — then the result rejoins the normal pandoc step. If `claude` declines to extract something (e.g. over copyright concerns) or a share extension hands off a raw URL disguised as a "file" (common with Reddit, LinkedIn, etc.), the webhook and script both detect and handle it rather than uploading a garbage or misnamed book.
- [kepubify](https://github.com/pgaskin/kepubify) converts the EPUB into Kobo's `.kepub.epub` format for reading-stats/page-turn support.
- [rclone](https://rclone.org) uploads the result to a specific Google Drive folder.
- Before each send, files older than a configurable age are purged from that Drive folder — KoboCloud has no "delete after sync" feature of its own, and there's no way to confirm from the client side that the Kobo has actually pulled a given file, so this is a time-based approximation.

The webhook queues the job and returns immediately (HTTP 202) — Cloudflare's edge kills connections after ~100s, well short of what a `claude -p` fetch or PDF conversion can take, so the actual send always runs in the background on the server.

## Requirements

**On the server** (anything always-on and reachable — a Linux box, in this setup):
```
sudo apt install pandoc rclone                                     # or: brew install pandoc rclone
mkdir -p ~/.bin
curl -fsSL -o ~/.bin/kepubify https://github.com/pgaskin/kepubify/releases/latest/download/kepubify-linux-64bit
curl -fsSL -o ~/.bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x ~/.bin/kepubify ~/.bin/cloudflared
curl -fsSL https://bun.sh/install | bash                           # installs bun
```
(kepubify/cloudflared have no macOS builds referenced above — swap in the `-darwin` release asset if your server is a Mac instead of Linux.)
- [Claude Code](https://claude.com/claude-code) CLI (`claude`) — used only for PDF and URL conversion
- A domain on Cloudflare DNS, for a tunnel hostname (e.g. `kobo.yourdomain.com`)
- A KoboCloud installation on the Kobo, watching a Google Drive folder (see KoboCloud's own docs for that setup)
- An rclone remote configured for that Google Drive folder: `rclone config`

**On the Mac / iPhone**: nothing but `curl` (Mac) or the Shortcuts app (iPhone) — no pipeline dependencies.

## Setup

### Server

1. Install the dependencies above.
2. Copy `kobo-send.conf.example` to `~/.config/kobo-send/config` and fill in your rclone remote name and Drive folder ID.
3. Install `kobo-send.sh` to `~/.bin/kobo-send.sh` (`chmod +x`).
4. Generate a bearer token and save it: `openssl rand -hex 32 > ~/.config/kobo-send/webhook-token && chmod 600 ~/.config/kobo-send/webhook-token`
5. Install `server/kobo-webhook.ts` to `~/.bin/kobo-webhook.ts`.
6. `cloudflared tunnel login`, then `cloudflared tunnel create kobo-send` and `cloudflared tunnel route dns kobo-send kobo.yourdomain.com`.
7. Copy `server/cloudflared-config.yml.example` to `~/.cloudflared/config.yml`, filling in your tunnel ID and hostname.
8. Install `server/systemd/*.service` to `~/.config/systemd/user/`, then:
   ```
   sudo loginctl enable-linger $USER   # keep user services running without an active login session
   systemctl --user daemon-reload
   systemctl --user enable --now kobo-webhook.service cloudflared-kobo.service
   ```

### Mac

1. Copy the webhook token to `~/.config/kobo-send/webhook-token` (`chmod 600`) — same value as the server's.
2. Install `kobo-send-client.sh` to `~/.bin/kobo-send-client.sh` (`chmod +x`), with `WEBHOOK_URL` in it pointed at your tunnel hostname.
3. One-time: Shortcuts app → Settings… → Advanced → enable **Allow Running Scripts** (required for the `Run Shell Script` action used below).
4. Build two Shortcuts (no Automator `NSServices` involved — see Known limitations for why that route was retired):
   - **Send File to Kobo** (files): New Shortcut → **Get Contents of URL** → `https://kobo.yourdomain.com/send`, Method **POST**, Headers `Authorization: Bearer <your webhook token>`, Request Body **Form**, one field `file` (type **File**) = **Shortcut Input**. In the shortcut's settings (ⓘ), enable **Use as Quick Action → Share Sheet**, restrict accepted types to **Files**. This POSTs straight to the webhook — no local script involved, and no dependency on `kobo-send-client.sh`.
   - **Send Page to Kobo** (URLs): New Shortcut → add **Run Shell Script** (Shell `/bin/zsh`, Input **Shortcut Input**, Pass Input **as arguments**), script `"$HOME/.bin/kobo-send-client.sh" "$1"`. In the shortcut's settings (ⓘ), enable **Use as Quick Action → Share Sheet**, restrict accepted types to **URLs**. (This one goes through `kobo-send-client.sh` rather than a direct `Get Contents of URL` because the JSON-body Value field's variable-insertion UI was flaky in testing — see Known limitations.)
5. It'll now show up under **right-click → Share → Shortcuts** in Finder (files) and under Safari's Share button (pages).

### iPhone

Build two Shortcuts (Share Sheet-enabled) that `POST` to `https://kobo.yourdomain.com/send` with header `Authorization: Bearer <token>`:
- **Send Page to Kobo** — accepts URLs, Request Body: JSON, field `url` = Shortcut Input.
- **Send File to Kobo** — accepts Files, Request Body: Form, field `file` (type File) = Shortcut Input.

## Usage

From Finder, right-click a file → Share → Shortcuts → **Send to Kobo**.

From Safari, use Share → **Send Page to Kobo** to send the current page.

From an iPhone, use the Share sheet → **Send Page to Kobo** / **Send File to Kobo**.

Or run the client directly on the Mac:

```
kobo-send-client.sh ~/Documents/report.pdf
kobo-send-client.sh https://example.com/some-article
```

## Known limitations

- Modern macOS no longer reliably runs legacy Automator Services (`NSServices`) for either Safari's whole-page actions or Finder's file actions — both the original "Send Page to Kobo" Safari Service and the "Send to Kobo" Finder Quick Action stopped working some time after they were first set up, with no error or deprecation notice (the Finder one loaded and even ran per macOS's own process logs, but silently never executed its embedded shell script). Both are replaced by Shortcuts-app Shortcuts (Share Sheet) instead; see Setup → Mac.
- The Shortcuts editor's JSON-body table is flaky for inserting a magic variable into a `Value` cell (both drag-and-drop and Edit → "Insert Variable" failed in testing) — the file-sending Shortcut avoids this by using a Form body instead (its File-type Value field doesn't hit the bug), and the page-sending Shortcut avoids it by going through `kobo-send-client.sh` via **Run Shell Script** instead of building the POST directly.
- The "Send File to Kobo" Shortcut's `Get Contents of URL` File-type field only accepts a single item — sharing multiple files at once silently sends just the first one.
- PDF and web-page conversion quality depends on `claude -p`'s extraction — it's generally good for article-shaped content, less reliable for complex multi-column layouts, heavily scripted pages, or sites requiring a login (e.g. LinkedIn) — `claude -p` doesn't emulate a real browser session, so auth-gated content often can't be fetched at all.
- The Drive-folder purge is time-based, not sync-confirmed — set `PURGE_OLDER_THAN` generously if your Kobo doesn't connect to WiFi often.
- Since the webhook responds before the job finishes, the Mac/iPhone confirmation only means "queued," not "done" — check the Drive folder (or the server's `journalctl --user -u kobo-webhook.service`) if a send seems to have gone missing.
