# Tray for Claude

Your Claude chats by the Windows clock. Read, reply, answer Claude's questions and run the steps it gives you
without leaving what you're doing.

![Tray for Claude: the panel above the clock, next to an editor](docs/hero.png)

> **0.2.x preview.** Works daily, still moving. Issues welcome.

- **Every chat, one row.** Reply in place, stop, retry, send and open files. Click a title for the full conversation.
- **Steps in one click.** In `/tray` chats, Claude's PC steps come with its reply: run (hidden, output captured),
  open, answer. Say "check" and Claude reads the results.
- **Nothing waits unseen.** Permission prompts and questions show in the panel, answerable there. A **?** on the
  chat and on the icon means Claude is waiting on you.
- **Usage at a glance.** Session and week limits, with alerts at 80 / 95 %.

<p>
  <img src="docs/question.png" width="340" alt="A question from Claude, answered in the panel">
  <img src="docs/compact.png" width="340" alt="Compact mode, light theme: one line per chat">
</p>

## Install

1. Download or `git clone` this folder somewhere you can write to, e.g. `C:\Tools\ClaudeTray`.
2. In PowerShell, in that folder:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\ClaudeTray.ps1 -WebLogin
   ```

   Sign in to claude.ai in the window that opens, then close it. The icon appears by the clock and starts with
   Windows.
3. Optional, for one-click steps: upload `skill/tray.zip` as a skill in Claude, and start a chat with `/tray` (the
   panel's `/tray` chip adds it for you).

Requires Windows 10 (1809+) or 11 with Edge and WebView2 (both ship with Windows), and a paid Claude plan.
No installer, no admin rights.

## Shortcuts

| To | Do |
| --- | --- |
| Show / hide the panel | Click the tray icon |
| Open the Claude app | Double-click the tray icon |
| Collapse / expand all chats | Click the grip at the top |
| Move the panel (it stays there) | Drag the grip |
| Keep it on top | Pin, bottom left |
| Resize · zoom | Drag any edge · Ctrl + wheel |
| Send · new line | Enter · Shift + Enter |
| Claude's slash commands | Type `/` in a reply box |
| Attach files | Paste, drop, or the clip |
| Pin, move, hide, open on claude.ai | Right-click a chat title |
| Bring any chat in | **Browse claude.ai**, bottom of the list |
| One line per chat | Settings › Compact mode |

## Commands

Run as `powershell -NoProfile -ExecutionPolicy Bypass -File .\ClaudeTray.ps1 <command>`.

| Command | |
| --- | --- |
| `-WebLogin` | Sign the tray's browser in to claude.ai, then start. |
| *(none)* · `-Restart` | Start · restart in the background. |
| `-QuestRoot <folder>` | Folder shared with Claude for steps and results (optional). |
| `-Install` · `-Uninstall` | Add · remove the Start-menu and startup shortcuts. |
| `-Set key=value` | Change one setting in `config.json`. |

## Privacy

- **Talks to Anthropic only**, over HTTPS. No telemetry, no analytics, no third parties.
- **Chats** are read in the tray's own hidden Edge (separate profile in `%LOCALAPPDATA%\ClaudeTray`), signed in by
  you, one tab per tracked chat. Only the chats you track, only what the panel shows.
- **Steps run only when you click them.** Programs and scripts Claude sends as files are shown in their folder,
  never started.
- **Local files** (`config.json`, `state.json`, `logs\`) are git-ignored. Logs hold no message text, titles or
  tokens.
- The hidden Edge is driven over the DevTools protocol on `127.0.0.1`; while it runs, another program on your PC
  that finds that port could use it, as with any browser in remote-debugging mode. It closes when the tray exits.

Remove everything: `-Uninstall`, delete the folder and `%LOCALAPPDATA%\ClaudeTray`.

## Troubleshooting

- **No chats / dash in the icon:** Settings › Sign in to claude.ai.
- **"running scripts is disabled":** use the full command above (`-ExecutionPolicy Bypass` applies to that run only).
- **Anything else:** Settings › Debug logs, reproduce, attach `logs\claudetray.log` to an issue.

More: [CHANGELOG](CHANGELOG.md) · [BACKLOG](BACKLOG.md) · [protocol](docs/PROTOCOL.md) · [for maintainers](AGENTS.md)

## Disclaimer

Unofficial, community-made. **Not affiliated with or endorsed by Anthropic.** "Claude" is a trademark of Anthropic;
"for Claude" only says what it works with. It drives claude.ai in your own signed-in browser and reads data that
isn't a published API, so it may stop working at any time. Use at your own risk, under your own agreement with
Anthropic. MIT License, provided as-is: see [LICENSE](LICENSE).
