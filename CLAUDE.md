# kobo-send

Bash pipeline + macOS Quick Actions that send a file or web page to a Kobo Clara 2E: `input --(pandoc)--> epub --(kepubify)--> .kepub.epub --(rclone)--> Google Drive folder`, which [KoboCloud](https://github.com/fsantini/KoboCloud) on the device syncs over WiFi.

## Layout

- `kobo-send.sh` — the whole pipeline. Deployed to `~/.bin/kobo-send.sh` on the target Mac (not run from this repo checkout).
- `kobo-send.conf.example` — template for `~/.config/kobo-send/config`, which holds the real, untracked `GDRIVE_REMOTE`/`GDRIVE_FOLDER_ID`/`PURGE_OLDER_THAN` values. Never commit real values.
- `automator/*.workflow` — Finder Quick Action ("Send to Kobo", files) and Safari Service ("Send Page to Kobo", URLs). Both are thin `Run Shell Script` wrappers calling `~/.bin/kobo-send.sh`. Installed by copying into `~/Library/Services/`.

## Key implementation details worth knowing before touching this

- **kepubify's output filename is not predictable.** It has varied across versions (`<stem>.kepub.epub` vs `<stem>_converted.kepub.epub`), so the script globs for `${STEM}*.kepub.epub` rather than hardcoding it. Don't reintroduce a hardcoded suffix.
- **Two separate title-page mechanisms exist and both need suppressing**: pandoc's own title page (`--epub-title-page=false`) and kepubify's heuristic-triggered dummy first page (`--no-add-dummy-titlepage`). Removing only one leaves a blank/title page on the device.
- **pandoc can't read PDF or fetch URLs.** Both those input types go through `claude -p` first (with a narrowly scoped `--allowedTools "Read"` or `--allowedTools "WebFetch"`, not a blanket permission bypass) to produce clean Markdown, stripping ads/nav/boilerplate, before rejoining the normal pandoc step.
- **KoboCloud has no "delete source after sync" feature**, and there's no way from the Mac side to confirm the Kobo has actually pulled a file (that only shows in `get.log` on the device). The `PURGE_OLDER_THAN` cleanup at the top of the script is a time-based approximation, not a real sync confirmation — don't present it as more reliable than that.
- Automator/Quick Actions run with a near-empty `PATH`, hence the explicit `export PATH=...` at the top including `~/.local/bin` (where `claude` typically lives via its installer) and the Homebrew prefixes for both Apple Silicon and Intel.

## Testing changes

There's no automated test suite — this is a personal utility script. To verify a change:
```
~/.bin/kobo-send.sh /path/to/test-file.pdf
rclone lsf <remote>: --drive-root-folder-id <id>   # confirm the upload landed
```
After editing `kobo-send.sh`, remember to `cp` it back into `~/.bin/kobo-send.sh` — that's the copy Automator actually invokes, not this repo checkout.
