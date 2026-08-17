# AI Quotas — macOS menu bar app

Your Claude and Codex usage limits, always visible in the menu bar:

```
Claude 4h ▰▰▱▱▱▱ 30%    Codex 6d ▰▰▰▰▱▱ 72%
```

Click for the full breakdown. Bars run green → amber → red as you approach a limit, and the
dimmed `4h` / `6d` before each bar is how long until that window resets.

Native Swift/SwiftUI, no third-party dependencies, and no AI Quotas cloud service.

## Before you start

**You need both CLIs installed and signed in.** This app has no login of its own — it
reuses the credentials the CLIs already store, so if you aren't logged in, that provider
shows an error card instead of a bar.

| Provider | Requirement | Check with |
|---|---|---|
| Claude | [Claude Code](https://claude.com/claude-code) installed and signed in | `claude` |
| Codex | [Codex CLI](https://developers.openai.com/codex/cli) installed and `codex login` done | `codex` |

You also need Xcode command line tools (`xcode-select --install`).

Only one of the two? The app still works — the other just shows an error card. Nothing breaks.

## Build & install

```bash
cd mac
./build.sh /Applications     # build and install to /Applications
open -a AIQuotas             # launch
```

`./build.sh` with no argument builds into `build/` without installing.

The compile is optimised and single-shot, so expect **1–2 minutes of no output** before it
finishes. That's normal, not a hang.

The app is **ad-hoc signed**, so on first launch macOS may say it "cannot be opened because
Apple cannot check it for malicious software." Right-click the app in Finder → **Open** →
**Open** to get past it. This is expected for a locally built app and only happens once.

Look for the bars in your menu bar, top-right near the clock. There's no Dock icon by design.

## Customising it

Click the menu bar item → **Settings…**

| Setting | Default | Notes |
|---|---|---|
| Claude / Codex label | `Claude` / `Codex` | Any text. **Leave empty to hide that label** and show just its bar. |
| Bar width | 42 pt | 16–240. Wider bars make the level easier to read. |
| Bar height | 7 pt | 3–22. Capped at 22 because that's the menu bar's height. |
| Show percentages | on | Off gives bars only. |
| Show time until reset | on | The dimmed `6d` / `4h` before each bar. |
| Nudge left | 10 pt | 0–2,000. Blank padding on the right that shifts the readout leftward — see below. |
| Refresh every | 5 minutes | 1 min – 1 hour. |
| Launch at login | off | |

Changes apply immediately. A note on tall bars: at 22 pt with the default 42 pt width the
corner radius makes the fill look like an oval — if you want tall, go wider too.

### Moving it left

macOS packs status items right-to-left from the clock and exposes **no API for positioning
one**. ⌘-dragging reorders items relative to each other, but can't create distance.

The workaround is **Nudge left**, which pads blank space onto the right of the drawn image.
Since the item is anchored on its right edge, the visible content shifts left by however much
you add. 240 pt of padding moves it 240 pt left.

Two limits worth knowing:

- The padding is part of the item's clickable area, so a big value means some clicks land on
  empty space. The popover still opens under the bars rather than the padding.
- It can't cross into the application menus (File, Edit, View…) — those own the left side, and
  a wide item plus large padding will simply be pushed back or truncated by the system.

## Reading the display

Each provider's bar shows its **highest** window — usually the 5-hour for Claude, the weekly
for Codex. Open the panel for every window individually.

- **Claude** — 5-hour session, 7-day, and overage if your plan has it
- **Codex** — your plan's primary window (weekly on Team), plus a secondary if present

**Overage** is different from the others: it tracks pay-as-you-go usage *beyond* your plan,
so 0% is where you want to stay. It only appears when your plan actually has it enabled.

A `cached` pill means the numbers came from local session logs because the provider was
unreachable. A `rate limited` pill means you've hit the limit right now.

## How the numbers are fetched

Each provider is checked locally through its installed CLI session:

- **Claude** — a 1-token request to the cheapest model, reading the
  `anthropic-ratelimit-unified-*` response headers.
- **Codex** — asks the documented Codex app-server API for `account/rateLimits/read`. Codex owns
  authentication and token refresh, and no model response is generated.

Cost is effectively zero, but these do count as requests against your account — which is why
the default refresh is 5 minutes rather than continuous.

The app refreshes Claude's OAuth session shortly before its access token expires. It uses Claude
Code's refresh lock and writes the rotated token back to the same credential store so both apps
stay in sync. Codex continues to own its authentication through app-server.

If Codex is unreachable, it falls back to the newest rate-limit snapshot in `~/.codex/sessions`
and marks the card `cached`.

Some similar tools read only local logs to avoid API calls entirely. That works for Codex,
which does log its limits, but it can't give accurate Claude numbers — those end up estimated
from token counts rather than real quota.

## The keychain prompt problem

Worth knowing about, because it bites most apps in this category and the fix is unobvious.

Claude Code stores its OAuth token in the macOS keychain. Keychain items grant access to
specific **code identities**, and Claude Code's item trusts exactly one:

```
applications (1):
    0: /usr/bin/security (OK)
       requirement: identifier "com.apple.security" and anchor apple
```

Any other reader triggers an "AI Quotas wants to access…" prompt. Worse, a locally-signed
app's identity is its **cdhash** — a hash of the binary — so the prompt returns after every
rebuild. Clicking "Always Allow" never sticks.

The usual advice is to create a stable self-signed identity and pin the Designated Requirement
to the certificate rather than the cdhash. That's sound for apps storing their *own* secrets,
but it doesn't help here: it can't retroactively add a new identity to an ACL that Claude Code
already wrote.

**The fix used here:** access the keychain by shelling out to `/usr/bin/security` — the exact
Apple-signed binary the item already trusts. The trusted binary performs reads and the narrowly
scoped OAuth refresh update, so there's no prompt on every build. It's also how Claude Code
accesses the item. See `Sources/AIQuotas/Credentials.swift`.

AI Quotas updates only Claude's OAuth fields after a successful refresh. It takes Claude Code's
`.oauth_refresh.lock`, re-reads the credential after acquiring it, and atomically updates the
existing item so it cannot overwrite a refresh performed concurrently by the CLI.

## Privacy and provider support

- AI Quotas has no telemetry, analytics, remote server, or account system. Quota results remain
  in memory apart from the small diagnostic log described below.
- Checks necessarily contact Anthropic and OpenAI, whose normal account, retention, and workspace
  policies apply. Tokens are never written to the diagnostic log.
- Codex uses OpenAI's documented app-server rate-limit method. The Claude integration is
  experimental because it reuses Claude Code authentication and undocumented response headers.
- This independent project is not affiliated with, endorsed by, or supported by Anthropic or
  OpenAI.

## Troubleshooting

**"no Claude Code credentials found"** — run `claude` and sign in. Same for
`codex login` on the Codex side.

**A keychain prompt appears anyway** — means your Claude Code keychain item has a different
ACL than the default. Approving once per build is the workaround; a stable Developer ID
signature is the real fix (see Sharing below).

**Codex shows an error but Claude works** — update the Codex CLI and confirm `codex login`
succeeds. The app uses Codex's app-server account API and falls back to recent local quota
snapshots.

**Nothing in the menu bar** — check it's running with `pgrep -x AIQuotas`. If your menu bar
is crowded, macOS may have hidden the item; try widening it or quitting another menu bar app.

**Diagnosing a bad refresh** — every refresh appends a line to `~/Library/Logs/AIQuotas.log`:

```bash
tail -f ~/Library/Logs/AIQuotas.log
# 2026-08-03 12:41:05  refreshed — Claude=30% Codex=20%
# 2026-08-03 12:46:05  refreshed — Claude=error(no Claude Code credentials found) Codex=20%
```

The file is capped at ~256 KB and trims oldest-first, so it won't grow unbounded.

## Layout

```
Sources/AIQuotas/
  AIQuotasApp.swift          @main, AppDelegate, SettingsView
  StatusItemController.swift NSStatusItem, popover, tooltip
  MenuBarRenderer.swift      draws the gradient bars into one NSImage
  SettingsWindow.swift       the settings NSWindow
  QuotaPanel.swift           the dropdown UI
  QuotaStore.swift           refresh timer, parallel fetch, preferences
  Models.swift               QuotaWindow / ProviderResult
  Credentials.swift          keychain and local configuration helpers
  ClaudeProvider.swift       Anthropic
  CodexProvider.swift        OpenAI / ChatGPT through Codex app-server
  LoginItem.swift            launch at login
build.sh                     compiles, bundles, ad-hoc signs
```

Two deliberate departures from SwiftUI defaults, both documented in the files themselves:
`MenuBarExtra` is replaced by `NSStatusItem` (its label sizing clips or drops variable-width
text), and the `Settings` scene by a plain `NSWindow` (only reachable via private selectors
that silently no-op).

**Adding a provider:** write a `fetch()` returning a `ProviderResult`, add it to the
`async let` block in `QuotaStore.refresh()`, and give it a label in `QuotaStore.label(for:)`.
The menu bar and panel pick it up automatically, error cards included.

## Sharing it

Ad-hoc signed builds are per-machine: hand someone the `.app` and Gatekeeper will block it.
Share this repo and let people run `./build.sh /Applications` themselves.

For a double-clickable build, sign with a Developer ID and notarize:

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: Your Org (TEAMID)" AIQuotas.app
xcrun notarytool submit AIQuotas.zip --apple-id … --team-id … --wait
xcrun stapler staple AIQuotas.app
```

That also gives a stable code identity, which fixes the keychain prompt for anyone whose
ACL differs from the default.

## Notes

- Menu-bar only via `LSUIElement` — no Dock icon, no app switcher entry.
- Requires macOS 14+ on Apple silicon. `build.sh` targets `arm64` only; for an Intel Mac,
  change `-target arm64-apple-macosx14.0` to `x86_64-apple-macosx14.0`.
- A CLI and web-dashboard version of the same thing lives in the parent directory.
- Launch at login uses `SMAppService`; ad-hoc-signed apps are occasionally refused as login
  items, so verify it survives a restart before relying on it.
