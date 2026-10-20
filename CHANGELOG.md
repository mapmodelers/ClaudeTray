# Changelog

Versions follow [semver](https://semver.org): 0.x = preview, things still move. 1.0.0 = stable.

## 0.2.4

- Questions, several-answers step:
  - Each choice is read once (a hidden checkbox sat next to each one).
  - Picks show as selected.
  - Send answers presses the card's own send button: greyed until you pick something.

## 0.2.3

- Questions:
  - An "Other answer…" box in the card: Enter sends your own answer.
  - Send answers presses the card's send button, or the message box's.
  - Each choice is listed once (a checkbox inside its button was counted twice).
  - Every pick / next / send logs the card's layout and states (no text), to finish the several-answers step.

## 0.2.2

- Questions: the card no longer disappears from the tray on a step whose choices it can't read (the several-answers
  step). Back, Next, Skip and Send answers stay, and those choices are looked for as checkboxes too. A step like that
  logs its layout (structure only), so the next version can read it.

## 0.2.1

- Claude Code questions now really show in the tray, read from claude.ai's question card:
  - the question with its "1/2" step, the choices (with their descriptions on hover);
  - Next, Skip, and Send answers;
  - or type your own answer in the box below and send it.
  - 0.2.0 looked for the wrong kind of buttons and never found them.
- Compact mode: the title is bold, Claude's last line dimmer.
- Logs: at most one structure dump per chat every 30 s (opening / folding chats wrote one each time).

## 0.2.0

- **Compact mode** (Settings, off by default): a collapsed chat takes one line.
  - The dot opens the conversation.
  - The field shows the title with Claude's last line; click it and type.
  - Bell, open in Claude and age stay in place.
  - Esc brings the title back; an unsent draft shows in italics.
- Toolbar at the bottom, above usage: collapse / expand all, new chat, settings, pin. Menus open upward. The top bar is
  just the grip: drag it to move the panel, click it to collapse / expand all.
- Claude Code's multiple-choice questions show in the chat: pick, submit, or type your own answer below.
  - The chat opens by itself and counts as "needs you".
  - When one appears, its layout is logged (structure only, no text).
- Files from Claude open in one click: click the name. A copy stays in Downloads; programs and scripts are only shown
  in their folder, never run.
- Every icon shows its label on hover (Windows' tooltips never appeared: the panel doesn't take the focus).
- Titles are never white: grey, a bit brighter and bold when unread.

## 0.1.6

- Fix: a reply's copy / retry icons still covered its first line. They now sit at the end of that line, with the text
  wrapping around them, at any display scale or zoom.

## 0.1.5

- Choice steps: an `observe` step with `options` shows them as buttons; one click answers.
- Skill: when you do by hand something the tray could run (git, Perforce, builds, releases, installs...), Claude offers
  once, as Yes / No buttons, to give it as one-click steps from then on.

## 0.1.4

- Fix: messages to a chat that claude.ai moved to a new address (a session now opened as `/chat/<id>`) were refused or
  lost. When the chat's own link lands on a new address, the tray adopts it (kept across restarts) and sends there.

## 0.1.3

- A chat tab that drifted to another page (connection lost, error page) goes back to the chat by itself; a send that
  finds it there opens the chat first and still goes through.
- Settings: light / dark only; "Sign in to claude.ai" shows only when the tray's browser isn't signed in; the quest
  folder moved out of the panel menu (still in the tray icon's right-click menu).

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
- One sign-in (`-WebLogin`, or settings > Sign in to claude.ai): usage now comes from claude.ai through the tray's
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
