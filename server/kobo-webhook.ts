// HTTP front-end for kobo-send.sh: accepts a URL (JSON) or a file (multipart
// upload) over the Cloudflare Tunnel, bearer-token-gated. Queues the job and
// returns immediately (202) — Cloudflare's edge kills connections after ~100s,
// well short of what a claude -p fetch/PDF conversion can take, so the actual
// send always runs detached in the background.
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { timingSafeEqual as nodeTimingSafeEqual } from "node:crypto";

const TOKEN_FILE = join(process.env.HOME!, ".config/kobo-send/webhook-token");
const SCRIPT = join(process.env.HOME!, ".bin/kobo-send.sh");
const TOKEN = (await Bun.file(TOKEN_FILE).text()).trim();

function timingSafeEqual(a: string, b: string): boolean {
  const bufA = Buffer.from(a);
  const bufB = Buffer.from(b);
  if (bufA.length !== bufB.length) return false;
  return nodeTimingSafeEqual(bufA, bufB);
}

async function runInBackground(target: string, cleanupDir?: string) {
  const proc = Bun.spawn([SCRIPT, target], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  console.log(`[kobo-send] target=${target} exit=${exitCode}`);
  if (stdout) console.log(`[kobo-send stdout] ${stdout.trim()}`);
  if (stderr) console.log(`[kobo-send stderr] ${stderr.trim()}`);
  if (cleanupDir) await rm(cleanupDir, { recursive: true, force: true });
}

Bun.serve({
  hostname: "127.0.0.1",
  port: 8787,
  async fetch(req) {
    if (req.method !== "POST" || new URL(req.url).pathname !== "/send") {
      return new Response(JSON.stringify({ error: "not found" }), { status: 404 });
    }

    const auth = req.headers.get("Authorization") ?? "";
    const provided = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!timingSafeEqual(provided, TOKEN)) {
      return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
    }

    const contentType = req.headers.get("Content-Type") ?? "";

    if (contentType.startsWith("application/json")) {
      const data = (await req.json().catch(() => ({}))) as { url?: string };
      const url = (data.url ?? "").trim();
      if (!url) {
        return new Response(JSON.stringify({ error: "missing url" }), { status: 400 });
      }
      runInBackground(url);
      return new Response(JSON.stringify({ status: "queued", target: url }), { status: 202 });
    }

    if (contentType.startsWith("multipart/form-data")) {
      const form = await req.formData().catch(() => null);
      const file = form?.get("file");
      if (!file || !(file instanceof File) || !file.name) {
        return new Response(JSON.stringify({ error: "missing file" }), { status: 400 });
      }

      // Some share extensions (Reddit, LinkedIn, ...) don't expose a proper
      // URL type to Shortcuts, so a shared link arrives here as a "file"
      // whose name — or whose entire content — is just the URL text. Detect
      // that and route it through the real URL pipeline (title extraction,
      // refusal-guard) instead of uploading a book named after a raw link.
      const URL_RE = /^https?:\/\/\S+$/;
      let url: string | null = URL_RE.test(file.name) ? file.name : null;
      if (!url && file.size < 2048) {
        const text = (await file.text()).trim();
        if (URL_RE.test(text)) url = text;
      }
      if (url) {
        runInBackground(url);
        return new Response(JSON.stringify({ status: "queued", target: url }), { status: 202 });
      }

      const dir = await mkdtemp(join(tmpdir(), "kobo-webhook-"));
      const target = join(dir, basename(file.name));
      await writeFile(target, Buffer.from(await file.arrayBuffer()));
      runInBackground(target, dir);
      return new Response(JSON.stringify({ status: "queued", target: file.name }), { status: 202 });
    }

    return new Response(JSON.stringify({ error: "unsupported content-type" }), { status: 400 });
  },
});

console.log("kobo-webhook listening on 127.0.0.1:8787");
