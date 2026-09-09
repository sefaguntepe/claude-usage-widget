# Claude Usage Widget

A transparent desktop widget for Windows that shows how much of your
**Claude subscription's 5-hour and weekly rate limits** you have used — plus a
7-day history, a burn-rate warning, and optional threshold alerts.

It reads the numbers from two files Claude already writes on your machine —
Claude Code's status line (terminal sessions) and the Claude desktop app's own
usage history — and shows whichever was measured more recently. **No API
calls, no tokens, no quota spent to measure quota.**

*[Türkçe belgeler: README.tr.md](README.tr.md)*

![Usage widget](docs/widget.png)

## How it works

Claude Code passes session data to your configured `statusLine` script on
stdin, and that JSON contains the rate-limit fields:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
  "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
}
```

```
Claude Code ──stdin JSON──▶ durum-yaz.js ──▶ %APPDATA%\ClaudeKullanim\durum.json
                                 │                          │
                                 ▼                          ▼
                          status line in your          kullanim.ps1
                          terminal                     (the widget)
```

The same install also registers `Stop` and `Notification` hooks, so the widget
can tell you when Claude finished a long job or is waiting for permission.

### Second source: the desktop app

The desktop app never runs status line scripts, but while it is open it polls
`claude.ai/api/organizations/<org>/usage` **with its own session** every 15
minutes (for its tray/plan-usage feature) and appends the result to
`%APPDATA%\Claude\plan-usage-history.json`:

```json
{ "t": 1788923411336, "org": "…", "u": { "fh": 30, "sd": 94 } }
```

`fh` is the 5-hour percentage, `sd` the weekly one. The widget only **reads**
this file — no credentials, no network, no writes. The two sources are
snapshots of the same API; **the more recently measured one wins.** Cross-check
against the status line on the same minute: identical or 1 point apart; every
larger gap was the status line lagging behind.

The file has no `resets_at`, so when the desktop sample wins the countdown is
kept only if the status line's window is still open (reset in the future and
percentage not lower); otherwise it is left blank rather than guessed.

## When does the number update?

Two sources, one rule: **the more recently measured one wins.** Both are
snapshots of the same API, so the source never changes the number — only how
fresh it is.

| Source | Written when | Gives |
|---|---|---|
| **Terminal** — Claude Code status line → `durum.json` | On every Claude reply, plus every 30 s — only in an interactive terminal session | Percentages + reset times, instantly |
| **Desktop app** — its own `plan-usage-history.json` | Every **15 min** while the app is open; every **5 min** for 30 min after you right-click the Claude tray icon; paused while you are idle 10+ min | Percentages only |

The widget polls both files once a second. What the labels mean:

| You see | It means |
|---|---|
| `live` | Data from the terminal, event-driven |
| `desktop · 7 min ago` | Data from the desktop app's last sample, with its real age |
| `38% ▲` | Claude finished a turn ≥ 90 s after that measurement (hooks fire in the desktop app too). The real value is higher; the widget will not guess by how much |
| countdown | Shown only when the reset time is *known* (came from the terminal and that window is still open). The desktop file has none — left blank, not invented |
| grey bars + amber age | Both sources are silent (terminal > 5 min, desktop > 20 min). The number is correct but historical |

Working in the desktop app with no terminal: numbers refresh every 15 minutes,
with `▲` filling the gaps. Want it faster for a while? Right-click the Claude
tray icon once — 5-minute samples for the next 30 minutes. The widget itself
never touches the network or your credentials; it reads what two apps already
write to disk.

## Features

- **Works with the desktop app** — updates every 15 minutes from the app's own
  usage history, no terminal needed (every 5 minutes for half an hour after you
  open the app's tray usage popup). The age label says where the number came
  from and how old it is: `desktop · 7 min ago`.
- **▲ = "at least this much"** — hooks fire in the desktop app too, so when
  Claude finishes a turn after the last measurement the 5-hour percentage gets
  a `▲`: the real value is higher, the widget just will not guess by how much.
- **Two looks** — a desktop card, or a slim strip that sits on top of the
  taskbar with the two limits stacked. Right-click → *Appearance*. Each keeps
  its own position.

  ![Strip theme](docs/strip.png)

- **5-hour and weekly usage bars** with reset countdowns
- **Burn-rate projection** — bars turn red when the window will run out *before*
  it resets, even at moderate usage. A window at 60% that lost 30 points in the
  last 20 minutes is more dangerous than one sitting quietly at 85%.
- **7-day history** — daily consumption measured in "5-hour windows"
  (100 points = one full window, so `today 2.1×` means about two windows today)
- **Threshold alerts** — optional pop-up when a limit crosses a percentage you
  pick; fires once per window and re-arms when the window resets
- **Event line** — "Claude finished · +214 −37 · my-project" or
  "waiting for permission", driven by hooks
- **Honest about stale data** — dims and states *why* the numbers stopped
  updating instead of silently showing an old percentage
- **Enriched terminal status line** — model, reasoning effort, fast mode,
  active agent, output style, context %, limits, clickable PR link, and a
  version badge when your Claude Code is out of date

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (preinstalled)
- [Node.js](https://nodejs.org) — the status line and hook scripts run on it
  (chosen for start-up speed: ~136 ms versus ~399 ms for PowerShell, and this
  script runs often)
- Claude Code, signed in with a Claude.ai **Pro or Max** subscription
  (`rate_limits` is only sent to subscription accounts)

## Install

```powershell
git clone https://github.com/sefaguntepe/claude-usage-widget.git
cd claude-usage-widget
node statusline.js kur
powershell -ExecutionPolicy Bypass -File kur-baslangic.ps1
```

- `node statusline.js kur` registers the status line and the two hooks in
  `~/.claude/settings.json`. It **backs the file up first**, refuses to touch a
  status line that is not ours, and preserves other people's hook entries.
- `kur-baslangic.ps1` adds a Startup shortcut so the widget launches at sign-in.

Check the current state any time with `node statusline.js durum`.

## Important limitation — read this first

**The numbers advance only while one of the two sources is running:** a
terminal Claude Code session you are actively using, or the Claude desktop app
(15-minute cadence). Facts worth knowing:

1. The desktop app does not run status line scripts at all — that is why the
   second source exists.
2. `rate_limits` is **not a live query** — it is a snapshot from that session's
   last API response. Claude Code caches it and re-sends the same values every
   time the status line runs, so an *idle* terminal session keeps rewriting the
   file with values that never move. Leaving an idle session open does not
   help. The widget tracks when the values were last **measured**, not when the
   file was written; stale bars turn grey and the age label turns amber.
3. Desktop polling is 15 minutes normally, 5 minutes for 30 minutes after you
   open the tray usage popup, and pauses while you are idle for 10+ minutes.
   The widget shows the sample's real age rather than calling it live, and
   marks the 5-hour bar with `▲` when a Claude turn finished after the sample.
4. The desktop file is **undocumented** (schema version 2). The widget checks
   the version and silently ignores anything it does not recognise, falling
   back to the status line. The app also has a remotely configurable gate
   (`pollRequiresTrayOpenWithinHours`); if samples ever stop, click the tray
   icon once.

Deliberately **not** done: calling the usage API with your OAuth token (as
some monitors do). The token's scopes include `user:inference` — it is a full
account credential, not a read-only one — and Windows Credential Manager is
readable by any process in your session. Reading a file the app already writes
gets the same numbers with none of that.

Two further limits:

- Only `five_hour` and `seven_day` are available. The per-model weekly window
  that `/usage` shows has no local source.
- `rate_limits` arrives only after the session's first API response, so a brand
  new session briefly shows the previous value. The script never overwrites
  good data with empty data.

## Configuration

Right-click the widget:

| Menu | What it does |
|---|---|
| *Background* | Transparent / light / dark backdrop |
| *Alert threshold* | Per-window alert level — off, or 50–95% |
| *Reset position* | Move back to the top-right corner |
| *Close* | Quit |

Alerts are **off by default**. When one fires it stays until clicked, never
steals focus, and will not fire again for the same window even if usage keeps
climbing — the reset boundary is what re-arms it, not a timer.

Settings and data live in `%APPDATA%\ClaudeKullanim`.

## Uninstall

```powershell
node statusline.js kaldir
powershell -ExecutionPolicy Bypass -File kaldir-baslangic.ps1
```

The first command removes the status line and hooks (backing up
`settings.json` again). Then close the widget from its right-click menu and
delete `%APPDATA%\ClaudeKullanim` if you want the history gone too.

## Notes

- **Interface language follows Windows.** Turkish on a Turkish display language,
  English otherwise — no setting, no restart dance. Only `tr` and `en` are
  built in; adding another is a string table away.
- Because the widget never takes keyboard focus (so it can sit on the desktop
  without interrupting you), values are chosen from menus rather than typed.
- The `Stop` hook is handled carefully: returning exit code 2 from it would
  make Claude keep going instead of stopping, so `olay-yaz.js` wraps everything
  in try/catch and always exits 0. Preserve that if you modify it.

## License

MIT — see [LICENSE](LICENSE).
