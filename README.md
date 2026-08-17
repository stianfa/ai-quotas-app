# AI Quotas

See how much of your Claude and Codex usage limits you've burned through, in one place.

```
  AI Quotas  08:26:07

  Claude (team)
    5-hour session   █░░░░░░░░░░░░░░░░░░░░░░░░░░░   4%  resets in 4h 53m
    7-day            ░░░░░░░░░░░░░░░░░░░░░░░░░░░░   1%  resets in 12h 33m
    Overage          ░░░░░░░░░░░░░░░░░░░░░░░░░░░░   0%  resets in 3m

  Codex (team · premium)
    Weekly           █░░░░░░░░░░░░░░░░░░░░░░░░░░░   4%  resets in 6d 23h
```

There are no API keys to paste and nothing to configure. It reuses your existing Claude Code and
Codex sessions, and the app itself runs locally.

## What you need first

**This app has no login of its own.** It reads the credentials the CLIs already wrote, so you need
to be signed in to whichever providers you want to see:

| Provider | Requirement |
|---|---|
| **Claude** | [Claude Code](https://claude.com/claude-code) installed, and signed in (run `claude`) |
| **Codex** | [Codex CLI](https://developers.openai.com/codex/cli) installed, and `codex login` done |

**Only signed in to one of them? That's fine.** The other simply shows an error card telling you
what to run. Nothing else breaks.

Beyond that: **Node 18 or newer** for the CLI and dashboard. The menu bar app needs macOS 14+ and
Xcode command line tools (`xcode-select --install`) — see below.

Reading the keychain (Claude) currently makes this **macOS-only**.

## Pick a version

**On a Mac, you probably want the menu bar app.** Your quotas stay visible without running
anything:

```
Claude 4h ▰▰▱▱▱▱ 30%    Codex 6d ▰▰▰▰▱▱ 72%
```

```bash
cd mac && ./build.sh /Applications
open -a AIQuotas
```

Full setup, settings, and troubleshooting: [`mac/README.md`](mac/README.md). Two things to expect
on a first build — the compile sits silent for 1–2 minutes, and because the app is ad-hoc signed,
macOS may refuse to open it until you right-click → **Open**. Both are normal and covered there.

**Otherwise use the CLI**, which needs no build step:

```bash
node src/cli.js              # print once
node src/cli.js -w           # live view, refreshes every 60s
node src/cli.js -w 10        # ...every 10s
node src/cli.js --serve -o   # web dashboard, opens in your browser
node src/cli.js --json       # machine-readable, for scripts
```

Equivalent npm scripts: `npm run quotas`, `npm start` (dashboard). `--port <n>` moves the
dashboard off the default 4317, and `node src/cli.js --help` lists everything.

No dependencies, so there's no `npm install` to run.

To get `ai-quotas` on your PATH from anywhere:

```bash
npm link
```

## What the numbers mean

| Provider | Windows shown |
|---|---|
| **Claude** | 5-hour session, 7-day, and overage when your plan has it |
| **Codex** | Your plan's primary window (weekly on Team), plus a secondary one if present |

Bars turn amber past 70% and red past 90%. Reset times count down live.

**Overage reads differently from the rest** — it tracks pay-as-you-go usage *beyond* your plan, so
0% is where you want to stay. It only appears if your plan has it enabled.

A `cached` tag means the numbers came from local session logs because the provider was unreachable.
`RATE LIMITED` means you're at the limit right now.

## Troubleshooting

**"no Claude Code credentials found"** — run `claude` and sign in. For Codex, run `codex login`.

**"Token rejected"** — your saved login expired past the point of refresh. Sign in again with
`claude` or `codex login`.

**Codex errors while Claude works** — update the Codex CLI and confirm `codex login` succeeds.
AI Quotas uses the CLI's app-server account API and falls back to recent local quota snapshots.

**A macOS keychain prompt appears** — expected only for the menu bar app on some setups;
[`mac/README.md`](mac/README.md) explains why and what to do.

## How it gets the data

Each provider is checked locally through its installed CLI session:

- **Claude** — a 1-token request to `api.anthropic.com`, reading the `anthropic-ratelimit-unified-*`
  headers.
- **Codex** — asks the documented [Codex app-server API](https://developers.openai.com/codex/app-server/#6-rate-limits-chatgpt)
  for `account/rateLimits/read`. The Codex CLI owns authentication and token refresh, and no model
  response is generated.

The macOS app refreshes Claude's OAuth session shortly before its access token expires, using
Claude Code's refresh lock and updating the same Keychain item with the rotated credentials.
Codex refreshes its own session through app-server. The Node CLI remains read-only and asks
Claude Code to refresh an expired session.

If Codex can't be reached, it falls back to the most recent quota snapshot in your session logs and
marks the card `cached` so you know it isn't live.

### Cost

Effectively zero. The Claude poll caps output at 1 token on the cheapest model; the Codex account
query generates nothing. The server caches for 15 seconds and the dashboard polls once a minute.

### Where credentials are read from

Nothing is copied into this repository or an AI Quotas data store, and tokens are never logged.

| Provider | Access |
|---|---|
| Claude | From macOS keychain service `Claude Code-credentials` (falling back to `~/.claude/.credentials.json`), then sent only to Anthropic. The macOS app persists OAuth token rotation back to that same store. |
| Codex | Through the local `codex app-server`; AI Quotas does not read `auth.json` directly |

The local server binds to `127.0.0.1` only.

### Privacy, support, and provider status

- AI Quotas has no telemetry, analytics, remote server, or account system. Quota results stay in
  memory and are shown only in the local CLI, menu bar, or dashboard.
- Quota checks necessarily contact Anthropic and OpenAI. Their normal account, retention, and
  workspace policies apply to those requests.
- Codex uses OpenAI's documented app-server rate-limit method. The Claude integration is
  experimental: it reuses Claude Code authentication and depends on undocumented response headers,
  which Anthropic may change.
- This is an independent project and is not affiliated with, endorsed by, or supported by
  Anthropic or OpenAI.

Provider changes fail visibly with a hint rather than silently displaying invented live values.

## Adding another provider

Each provider is one self-contained file. Create `src/providers/<name>.js` exporting a function that
returns `ok()` or `fail()` from `base.js`:

```js
import { makeWindow, ok, fail } from './base.js';

export async function fetchGemini() {
  // ...read credentials, call the API, pull out the limits
  return ok({
    id: 'gemini',
    name: 'Gemini',
    plan: 'pro',
    windows: [makeWindow({ id: 'daily', label: 'Daily', usedPercent: 12, resetsAt: 1786341166 })],
  });
}
```

Then add it to the list in `src/providers/index.js`. The CLI and dashboard pick it up with no
further changes — including the error card if credentials are missing.

The menu bar app is separate; [`mac/README.md`](mac/README.md) covers adding a provider there.

## Layout

```
src/providers/base.js     shared result, keychain-read, and network helpers
src/providers/claude.js   Anthropic
src/providers/codex.js    OpenAI / ChatGPT
src/providers/index.js    registry + parallel fetch
src/server.js             local HTTP server & JSON API
src/cli.js                terminal UI and entry point
public/                   dashboard (vanilla JS, light + dark)
mac/                      the macOS menu bar app (Swift) — see mac/README.md
```

Providers are queried in parallel, and one failing never hides the others.

## License

MIT — see [LICENSE](LICENSE). Use it however you like.
