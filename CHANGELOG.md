# Changelog

Versions follow [semver](https://semver.org): 0.x = preview, things still move. 1.0.0 = stable.

## 0.3.5

- Fix: a long chat could show only its newest messages, or jump back to very old ones after you scrolled up.
  Messages the tray has seen are kept by claude.ai's row number, scrolling up reads the page just above and puts the
  hidden page back at the bottom (where the newest reply, its status and its steps are read).
- Fix: scrolling up did nothing on some chats ("no scroller"): the scrolling part of the page is found more widely.
- BROWSE: the chat list is read as soon as the tray's browser is ready, not only when BROWSE opens. If claude.ai
  doesn't answer (right after a reboot, say), it tries again after 15 s, 30 s, 1 min… up to every 5 min, and keeps
  the last list it had. Reading it may take up to 45 s, a project up to 30 s.
- When claude.ai can't be reached for a minute, the panel greys out with "claude.ai not reachable – reconnecting…"
  and a Reconnect button. After 90 s it reconnects by itself (at most every 5 min).
- Double-clicking the tray icon opens the Claude app also when the panel is pinned, and starts it when it isn't
  running (Microsoft Store install included).
- One chat open at a time: clicking a chat's dot opens it and closes the others. Right-click the dot to open it next
  to the ones already open. New steps open a chat only when none is open.
- One line per chat is now the only layout: the Compact mode setting is gone.
- A pinned panel no longer takes the focus when you click the grip or a button, so the app in front stays in
  front and a hidden taskbar stays hidden (a full-screen video, say). It takes the focus only when you click a text
  field or the conversation, to type or select.

## 0.3.4

- The panel keeps the height you gave it when you close a chat. Only collapse all (grip or toolbar) brings it back
  to its small size.
- Fix: fresh steps could show above the message you had sent before them, greyed out, instead of under Claude's
  reply. A message whose time says it came before the steps no longer counts as your answer to them.

## 0.3.3

- BROWSE has no header row any more: a folder button on the toolbar, next to +, opens and closes it, and the
  refresh button sits next to its search field. The pin button is now first on the toolbar.
- Fix: in a long chat the conversation could show old replies right above your latest message. claude.ai keeps only
  part of a long chat on the page; the tray now places each message by claude.ai's own row number and shows only the
  unbroken run that ends with the newest one. Scrolling up loads the messages just above, a page at a time.
- Fix: Claude Code's tool rows ("Read b1.png", "Saving files…, running a command…") no longer show as white lines in
  the conversation. What Claude is doing stays on the one grey line next to the animation.
- The conversation no longer loads earlier messages by itself to fill the space.

## 0.3.2

- Fix: Check for updates failed in a git clone ("git fetch failed") when a tag had been made again on GitHub. It now
  asks GitHub for the release tags without changing your local tags, and an update downloads only the release it
  moves to.

## 0.3.1

- Open chats use the whole panel once you have set its height (drag the top edge). The reply box sits at the
  bottom, the latest message just above it, and earlier messages load by themselves to fill the space. Pinned chats
  included.
- With two or more chats open, drag the line between them to give one more room. Double-click it to share evenly.
- BROWSE has its own pane above the toolbar: drag the line above it to make it taller or shorter.
- Top edge: the whole top band resizes the panel, except the grip itself.
- What Claude is doing ("Running a command", the spinner word) shows on one grey line next to the animation, and no
  longer lands in the reply text.
- Claude Desktop local chats no longer need a setting: they show in BROWSE when Desktop has some, and nothing runs
  for them until you track one. Settings > Claude Desktop local chats appears only then.
- Settings > Check for updates. Only when you click it: a git clone fetches the tags with your own git and moves to
  the newest release (fast-forward only, never over your changes); a zip install downloads the release from GitHub
  and keeps your settings, sign-in and logs. The tray then restarts.
- The "All chats hidden" line is gone: BROWSE lists hidden chats.
- Fixes from a UI review:
  - Settings and + menus fit in a short panel (it grows while the menu is open); Esc closes the menu first.
  - No jump when a chat opens, no empty gap under the New chat form, no bouncing top edge at the end of a reply.
  - Typing several lines no longer scrolls the conversation away from the latest message.
  - A click no longer gets lost when the panel refreshes at that moment; buttons never stay greyed out.
  - Hover labels stay up to date and don't show during a drag. The list scrollbar can be grabbed.
  - A click on an edge without dragging no longer fixes the panel height; zoom and moving the panel keep the
    height right.

## 0.3.0

A field test on another PC (Claude Enterprise, Windows 11, Claude Desktop with Cowork) produced 38 fixes and
features. Nothing in the tray broke because of Enterprise. This version takes them in, with the merge fixes below.
Field notes: [docs/FIELD-NOTES-2026-10-21.md](docs/FIELD-NOTES-2026-10-21.md).

- Usage keeps updating when no claude.ai chat is open in the tray. It used to stop until a chat tab existed.
- When claude.ai answers the tray's browser with a Cloudflare check (HTTP 403), the panel says so.
  Settings > Open claude.ai in the tray browser clears it, and that entry is now always there.
- Panel:
  - the bottom edge stays put when the panel grows or shrinks;
  - the top edge resizes again, and the resize zones are wider;
  - the grip restores exactly what was open before you collapsed;
  - clicking the tray icon hides or shows a pinned panel.
- Chats:
  - idle chats leave the tray after 10 minutes (Settings, 0 = never) and stay in BROWSE, where + brings them back;
  - titles are never bold (unread = brighter text);
  - new status marks.
- BROWSE: recent chats and projects in one list. Search covers every project. Hidden chats, Claude Code sessions
  included, are listed there with a +.
- Steps are numbered. After you answer a question or a request, the card says right away what happened.
- Model chip in the reply bar. On claude.ai chats and Claude Code sessions, a click lists the chat's models and
  effort levels and changes them in the chat (new).
- The `/tray` chip writes `/tray` in the box instead of acting as a hidden switch.
- Bridge mode: the `[tray]` line also carries the last output line of steps that succeeded.
- Skill: the field of each step kind is named (`cmd`, `path`, `url`).
- Claude Desktop local (Cowork) chats, experimental and off by default (Settings > Claude Desktop local chats):
  - they show in BROWSE and can be tracked;
  - their state and questions are read from Desktop's own files;
  - send / stop / answer work in the background;
  - permissions need two clicks, and Allow stays in Desktop (it ignores clicks from outside).
  - With it on, two more options: keep Desktop off-screen when minimized, and hide Desktop while the tray works in it.
- Merge fixes: the new-chat progress no longer gets lost (a comment had swallowed it), and 27 variables that reused
  global names were renamed. The field test's model change for Desktop local chats is dropped: it didn't work.

## 0.2.10

- Fix: fresh steps could be filed under an older message and not show at the end of the chat. A message you had
  already sent when the steps arrived no longer counts as your answer to them. Debug logs now note where each open
  chat's steps are placed.

## 0.2.9

- A step that fails now shows as failed. A PowerShell step used to report "exit 0" whatever happened (only the last
  command counted, and its code was dropped). Now its last command's code is kept, and an `error` / `fatal` line in
  the output marks it failed.
- Skill: multi-command steps check each command, so the first failure stops the step.

## 0.2.8

- README rewritten: shorter, with a shortcuts table, and new images made from the real panel with made-up chats
  (`tools/readme-shots.js`).
- Compact mode: a working chat's stop button no longer covers its row text. A permission prompt reads
  "Claude asks: Allow once / Deny".

## 0.2.7

- An unpinned panel no longer hides in the middle of a resize or a move (the cursor is outside it while you drag).

## 0.2.6

- **Claude waiting on you is clear everywhere.** A chat with an Allow / Deny prompt or a question:
  - shows an orange "?" instead of the working dots;
  - its row says "Claude asks: …";
  - it opens by itself.
  - The tray icon gets a "?" badge, ahead of "working" (Claude's turn is still running while it waits).
- **Browse claude.ai** is always the last section (click its title to open it) and replaces the "N hidden" line.
  - Hidden chats are listed at its top with a + to bring them back.
  - The + now sits left of each title.
- **Size:** with every chat collapsed (top grip or the toolbar), the panel shrinks to fit; your size comes back when
  a chat opens.
- **Pin:** resizing the panel no longer pins it; moving it still parks it there.

## 0.2.5

- The question card looks like claude.ai's, one line per row, in the tray's colors:
  - the question with ‹ n/m ›;
  - numbered choices (one answer) or checkboxes (several);
  - "Other…" with Skip, and Send answers.
- "Other…" goes into the card's own Other box:
  - with one answer, Enter sends it;
  - with several, it counts as one more choice next to your picks.
- Claude's Allow / Deny prompts use the tray's colors too (no more blue).

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
