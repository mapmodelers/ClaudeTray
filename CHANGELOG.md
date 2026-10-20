# Changelog

Versions follow [semver](https://semver.org): 0.x = preview, things still move. 1.0.0 = stable.

## 0.1.2

- An open chat keeps its title bar in view while you scroll the list.
- Settings show the version (bottom of the menu).
- Short replies from Claude is on by default: the skill now writes for the panel - outcome first, then blockers, steps,
  suggestions; no recaps. The setting is passed to Claude as `style terse` / `style normal`.

## 0.1.1

- A round's steps stay with the Claude reply they came from: once you answer (from the tray or the app), they scroll
  away with the conversation as a one-line-per-step record, and the chat no longer counts as "needs you".
- The tray reads each message's time when claude.ai shows it, to place them exactly.

## 0.1.0 - first public preview

- Name: **Tray for Claude** (the script and folders keep the short name `ClaudeTray`).
- One sign-in (`-WebLogin`, or the menu's Sign in for live chats): usage now comes from claude.ai through the tray's
  browser; `-Login` (Claude Code's sign-in) is only an optional fallback.
- Tray icon: plan usage as a ring (the limit you're closest to), dots for working / needs you / new reply; hover or
  click shows the panel, double-click opens the Claude app; usage alerts at 80 / 95 %.
- Panel (WebView2): every tracked chat as a row with a one-line reply box; click the title for the conversation, like
  the app - messages, rendered replies, links, code copy, files both ways (paste / drop / attach; save / copy Claude's),
  the page's questions (Allow / Deny), stop, retry, load earlier messages, read / unread.
- Steps (`/tray` chats): Claude's PC steps at the end of its reply - run hidden with output captured, open, answer,
  tick, skip; "check" sends the results through a file (or a `[tray]` line in bridge mode). The `/tray` chip adds the
  skill to a chat with your next message.
- Arrange: pin, hide (and bring back), sections, drag to reorder, sort by last used / name / project, Browse claude.ai
  (recent chats and projects), new chat (project, name, model, thinking), `/` command list. Layout kept across restarts.
- Panel: resize from any edge, drag to park, pin on top, zoom (Ctrl+wheel), light / dark, settings and right-click
  menus inside the panel.
- Start with Windows, when the Claude app opens, or manually. Debug logs setting for bug reports (no message text).
- Engine: a hidden Edge signed in to claude.ai (its own profile) with one tab per chat; stuck pages reloaded by
  themselves; one broken tab never stalls the others.
- Privacy: no chat titles, user name or paths in the log; token encrypted with DPAPI; temp files cleaned; the browser
  closes on exit.
