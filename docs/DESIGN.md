# ClaudeTray — design notes (next: sessions quest-log)

Status: **built** (WebView2 panel). Sections below = the agreed direction and the decisions taken on the way.


## Problem

Working with Claude (desktop app, sessions linked to this PC) means: Claude hands me numbered
steps (a `cmd`, a PowerShell line, a `.cmd` to run, a folder to open…), I run them, I report back
("check"). Nothing on the PC shows which chat is waiting for me or what it wants.

## Shape

- Tray icon = usage ring (as now) + a badge for the most urgent chat state.
- Flyout (pinnable to an always-on-top panel): one row per recent chat — marker · title · age · app · web · bell · ×.
  - `!` act — steps for me. `?` done — Claude finished, my turn. `⟳` working. `×` hides a chat; it returns when Claude writes to it again.
  - Expanded row: typed steps, each with its action; a field at the bottom (prefilled "check" when steps exist) → send; a robot button sends "do it yourself".
- Steps: `cmd` · `powershell` (▶ run hidden, result captured · ⧉ copy) · `.cmd/.exe` (▶ run · open folder) · `folder` · `file` · `link` · `manual` (✓ tick).
- Follows Windows light/dark; Claude-like palette; small text; icons only, no labels.
- Notifications: badge; bell toggle per chat.

## Protocol

See `PROTOCOL.md` and `skill/tray/SKILL.md`. Summary:

Claude can't be observed from outside; it can write. A skill (`/tray`, enabled per chat) makes Claude write, at the end of a
turn that has steps, `%USERPROFILE%\ClaudeTray\quests\<session>.json` (title, links, state,
summary, steps[]) — in addition to the short list in chat. Clicking ▶ runs the step hidden and
writes `results\<session>.json` (exit code, last lines). On "check", Claude reads results itself.
"working" is inferred (results newer than quest). Token cost: ~100 tokens per quest; results
replace pasted logs.

## Spike results (2026-10-19, app 2.42304, Windows 10)

- **Open a chat in the app:** `claude://claude.ai/<path>` (`chat/<uuid>` or `code/<session_id>`) — the app
  registers the `claude` URL scheme and navigates; it also brings the window forward. `claude://chat/<uuid>`
  does *not* navigate.
- **Send a message:** Windows UI Automation. The web content is exposed only after one
  `FindAll(Descendants)` on the window (wakes Chromium's accessibility); then the composer is the `Edit`
  with class `tiptap ProseMirror` → `SetFocus`, paste from clipboard, Enter. Proven end to end.
- **Also readable from the tree:** the sidebar chat list (one `Button` per chat, clickable via Invoke),
  the current chat title (`RootWebArea` document name), message texts, and a status line
  ("Claude a terminé sa réponse" — localized, so match by structure not text).
- Keep PowerShell (readable, one file) while the UI is small; C# if it grows.

## Tray icon

One icon, readable at 16 px. The ring + number = plan usage (binding limit) and always stays; the chat state is a
large badge in the top-right quarter (about half the icon, on a disc in the taskbar colour so it reads on light and
dark taskbars). Priority when several apply: asks you > working > needs you > new reply > idle (working + needs you: dots on a
blue ring). Only "working" moves - nothing pulses.

| State | Trigger | Look |
| --- | --- | --- |
| Working | Claude is generating in a visible chat (browser tab / app watcher) | 2x2 orange dots, one lit, going round (~1 s per turn) |
| Asks you | a visible chat's page waits on you: Allow / Deny / Continue / Send now, or a question card (beats working) | blue ring + blue disc with "?" |
| Needs you | a visible chat has steps for you | blue ring + blue dot |
| New reply | Claude finished or rewrote the quest after you last looked at that chat | purple dot |
| Idle | nothing pending | ring = usage, number = % |
| Usage high | binding limit >= 80 % / >= 95 % | arc orange / red |
| No data | not signed in / no usage yet / offline | dash in the ring |

"You looked at it" = its card is open in the panel, the panel is shown and the end of the conversation has been in
view for 1.5 s (read marks in `state.json`). The tooltip lists counts: "1 need you, 2 working, 1 new - session 18%, ...".
The animation timer only runs while Claude works. Review: `-Once` writes `logs\preview_states.png` (dark + light
taskbar, 16 and 24 px).

## Decided

Desktop-app sessions only (Claude Code CLI later, hook-based, see claudepulse-win). Hidden run
with capture. Flyout + pin. Steps stay in chat too.

## Backlog (not started)

- Paste screenshots / files into an answer box → saved under `<root>\results\<id>\` and referenced from the
  step's result (`files: [...]`), so Claude can read them with the results.
- Optional note field on manual steps.
- Claude Code CLI sessions via hooks (same quest files).
- Spike: a more direct way to open a given chat in the app / browser than `claude://claude.ai/<path>`.
