# kobo-send

Bash pipeline + webhook that sends a file or web page to a Kobo Clara 2E: `input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive folder`, which [KoboCloud](https://github.com/fsantini/KoboCloud) on the device syncs over WiFi.

The pipeline itself runs on an always-on Linux server, not on the Mac. The Mac (via Automator Quick Actions) and any iPhone (via Shortcuts) are thin clients that `POST` to a webhook exposed through a Cloudflare Tunnel — neither needs pandoc/kepubify/rclone/`claude` installed locally. (Real server hostname and tunnel domain are intentionally not in this file — this repo is public. Check `~/.config/kobo-send/` on your own deployment, or your shell history, for the actual values.)

## Layout

- `kobo-send.sh` — the whole conversion pipeline. Deployed to `~/.bin/kobo-send.sh` **on the server**, invoked by the webhook. Not run from this repo checkout, and no longer installed on the Mac.
- `kobo-send-client.sh` — thin curl-based client. Deployed to `~/.bin/kobo-send-client.sh` **on the Mac**; posts a file or URL to the webhook and lets the server do the work. Reads the bearer token from `~/.config/kobo-send/webhook-token`.
- `kobo-send.conf.example` — template for `~/.config/kobo-send/config` **on the server**, which holds the real, untracked `GDRIVE_REMOTE`/`GDRIVE_FOLDER_ID`/`PURGE_OLDER_THAN` values. Never commit real values.
- `server/kobo-webhook.ts` — the webhook itself (Bun/TypeScript). Bearer-token-gated, accepts a URL (JSON) or a file (multipart), queues the job, returns immediately (HTTP 202) since Cloudflare's edge times out connections after ~100s — the actual `kobo-send.sh` run happens detached, in the background. Deployed to `~/.bin/kobo-webhook.ts` on the server, run via `bun run`.
- `server/systemd/*.service` — systemd **user** units (`~/.config/systemd/user/`) for the webhook and the `cloudflared` tunnel process. Require `loginctl enable-linger $USER` so they survive logout/reboot without an active session.
- `server/cloudflared-config.yml.example` — template for `~/.cloudflared/config.yml` on the server; real file has an account-specific tunnel ID and credentials path, so isn't committed.
- `automator/*.workflow` — Finder Quick Action ("Send to Kobo", files) and Safari Service ("Send Page to Kobo", URLs), on the Mac. Both are thin `Run Shell Script` wrappers calling `~/.bin/kobo-send-client.sh`. Installed by copying into `~/Library/Services/`.
- No repo folder for the iOS Shortcuts — they're built directly in the Shortcuts app (see README's Setup section) since Shortcuts has no plain-text export format worth tracking.

## Key implementation details worth knowing before touching this

- **kepubify's output filename is not predictable.** It has varied across versions (`<stem>.kepub.epub` vs `<stem>_converted.kepub.epub`), so the script globs for `${STEM}*.kepub.epub` rather than hardcoding it. Don't reintroduce a hardcoded suffix.
- **kepubify rejects `.kepub.epub` inputs** (`invalid extension ".kepub.epub"`), so `kobo-send.sh` detects already-kepub files and uploads them as-is, skipping both conversion steps. Don't route them back through pandoc/kepubify.
- **Two separate title-page mechanisms exist and both need suppressing**: pandoc's own title page (`--epub-title-page=false`) and kepubify's heuristic-triggered dummy first page (`--no-add-dummy-titlepage`). Removing only one leaves a blank/title page on the device.
- **pandoc can't read PDF or fetch URLs.** Both those input types go through `claude -p` first (with a narrowly scoped `--allowedTools "Read"` or `--allowedTools "WebFetch"`, not a blanket permission bypass) to produce clean Markdown, stripping ads/nav/boilerplate, before rejoining the normal pandoc step.
- **`claude -p` sometimes refuses instead of erroring** (e.g. over copyright concerns on a news article) and writes a short refusal sentence to the Markdown file rather than failing loudly. `kobo-send.sh` treats any extracted content under 300 bytes as a failure rather than converting the refusal itself into a "book" — don't remove that guard without another way to detect refusals.
- **Any share-extension detail can hand the pipeline a raw URL disguised as a "file"** — Reddit's and LinkedIn's share sheets, for example, don't expose a proper URL type to Shortcuts, so a shared link can arrive as a file upload whose name (or whole content) is just the URL text. `server/kobo-webhook.ts` detects this (`/^https?:\/\/\S+$/` against the filename, then against the file's own content if small) and routes it through the real URL pipeline instead of uploading a book named after a raw link. `kobo-send.sh`'s file-input branch also sanitizes `STEM` unconditionally now, as a second line of defense — don't drop either check.
- **`claude -p`/WebFetch doesn't emulate a real browser.** No JS execution, no session/cookies — so login-gated pages (LinkedIn articles, paywalled sites) usually can't be fetched at all. Adding a headless-browser step was considered and deliberately deferred: the real limiter for LinkedIn is the login wall, not JS rendering, and an authenticated headless session raises ToS/account-risk concerns disproportionate to this tool's scope.
- **KoboCloud has no "delete source after sync" feature**, and there's no way from the client side to confirm the Kobo has actually pulled a file (that only shows in `get.log` on the device). The `PURGE_OLDER_THAN` cleanup at the top of `kobo-send.sh` is a time-based approximation, not a real sync confirmation — don't present it as more reliable than that.
- Automator/Quick Actions run with a near-empty `PATH`. `kobo-send-client.sh` only needs `curl` (built into macOS) so this matters less than it used to, but it still sets `PATH` explicitly for safety.
- `kobo-send.sh` runs on both macOS (if ever tested locally again) and Linux — it branches on `uname` for the notify() implementation (`osascript` vs `logger`/stderr) and PATH setup. Don't reintroduce a macOS-only assumption.

## Testing changes

There's no automated test suite — this is a personal utility script. To verify a change to `kobo-send.sh` or the webhook (substitute your own server host and tunnel domain):
```
ssh <server> '~/.bin/kobo-send.sh /path/to/test-file.pdf'               # direct pipeline test
curl -X POST https://<your-tunnel-domain>/send -H "Authorization: Bearer $(ssh <server> cat ~/.config/kobo-send/webhook-token)" \
  -H "Content-Type: application/json" -d '{"url":"https://example.com/article"}'  # webhook test
rclone lsf kobocloud: --drive-root-folder-id <id>                       # confirm the upload landed
ssh <server> 'journalctl --user -u kobo-webhook.service -n 50'          # check background job outcome
```
After editing `kobo-send.sh` or `server/kobo-webhook.ts`, remember to deploy both to the server (`~/.bin/kobo-send.sh`, `~/.bin/kobo-webhook.ts`) — that's what's actually running, not this repo checkout. Restart the webhook after changing it: `systemctl --user restart kobo-webhook.service` on the server. After editing `kobo-send-client.sh`, deploy it to `~/.bin/kobo-send-client.sh` on the Mac — that's what Automator invokes.
