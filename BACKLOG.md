# Backlog

What's asked, planned and still open. Done work moves to [CHANGELOG.md](CHANGELOG.md).

## Now

- Questions: working from the tray in 0.2.5 (pick, Next, Back, several answers + Other, Send; "looks functional").
  Not tried yet: Other + Enter on a one-answer step, Skip, a question with a single step.
- Images: thumbnails in the conversation (today a click opens them).
- Model / effort change (0.3.0): confirm on a real claude.ai chat and a Claude Code session; the effort sub-menu opens on hover (a mouse move is sent).
- Desktop local chats: untested on the classic installer, multi-org, PowerShell 7, other UI languages (see the field notes).
- Left from the 0.3.1 UI review: Windows' own resize loop for the edges (only if they feel jittery); "Send answers" for a Desktop local chat's question (the tray ignores it today).
- Activity line: check on a live Claude Code run that the status words no longer show in the reply text (FR + EN).
- Browse claude.ai: to rework (you'll say what). Left out of the README images until then.

## Decided

- Compact mode is a setting, off by default. In it, the dot opens a chat.
- Toolbar: its own thin bar above usage (not on the usage line).
- The one-line row shows Claude's last line after the title.

## Later

- Watch the 0.1.5 skill offers (git, P4V / `p4`, builds) in real chats; tune the wording if Claude over- or under-asks.

## Log of requests

- 2026-10-20: thin toolbar at the bottom above usage; top bar clear (click = collapse / expand all).
- 2026-10-20: one-line collapsed chats → "Compact mode"; the dot opens the chat; titles never white.
- 2026-10-20: icons must all show a label on hover.
- 2026-10-20: Claude Code questions must show properly in the tray.
- 2026-10-20: images / files viewable without a download or open-folder step.
- 2026-10-20: keep track of everything said; backlog what doesn't fit one run.
- 2026-10-20: compact mode - the title in the field must be bold.
- 2026-10-20: question card like the app's (checks, Other counts as one more choice), compact, themed colors.
- 2026-10-20: drop the hidden section (Browse brings chats back); + left of Browse titles; status must be accurate, "waiting on me" clear in the panel and the icon; collapse all = small panel; check pin / unpin.
- 2026-10-20: README rewritten (short, pro, shortcuts); images with made-up chats, one in-context shot, neutral gray background, no Browse.
- 2026-10-21: field test on Enterprise (by the author): 38 patches merged in 0.3.0. Local chats kept, off by default; park / hide only with them (settings); model / effort change wanted for claude.ai + Code chats; bridge line carries the last output line; tester's UI rules win (titles never bold, 10 min cooldown, bottom-anchored panel).
- 2026-10-21: top edge must resize around the grip (done, OK); BROWSE must be resizable (own pane, divider on top); local chats always on, no setting; no versioning or git until testing is over.
- 2026-10-21: BROWSE resize works but glitchy → full UI audit (smooth, bug-less); drop the "All chats hidden" line (BROWSE finds them).
- 2026-10-21: audit build OK ("nothing off so far"). Unused space under an open chat → conversations fill the panel, with a draggable limit like BROWSE.
- 2026-10-21: fill OK. The line above the reply box flickered and snapped back → replaced by a splitter between two open conversations (space shared by weight).
- 2026-10-21: one chat: didn't reach the bottom, couldn't resize, scrolled up while typing / on Enter → overflow guard + keep-at-latest while the reply box grows. Open question: should a lone chat be resizable (it fills by design)?
- 2026-10-21: blank area from the start = the chat was pinned (pinned chats sit outside the list, the fit measured the empty list and grew without end). Fixed: pins + list share the space.
- 2026-10-20: answers - last line after the title: yes; toolbar: own bar above usage; compact mode: off by default.
- 2026-10-21: status words ("Déchiffrage…", "En cours d'exécution", "Exécutant une commande") must be one grey line on the animation line, not in the reply. Then version 0.3.1 + README known issues / limits (local sessions).
- 2026-10-21: released 0.3.0 + 0.3.1 + 0.3.2 (update check fix). BROWSE header merged into the toolbar as a folder button at the right; pin first on the toolbar (0.3.3, to test).
- 2026-10-21: version only once a change is done and tested; Settings > Check for updates (from git).
- 2026-10-22: conversation mixes old replies above the latest one (must match Claude exactly); tool rows ('Lu b1.png', 'Enregistrant les fichiers…') still white in the reply. Auto-load of earlier messages removed; structure dump (debug) to find how claude.ai holds messages and tool rows.
- 2026-10-22: row-number fix OK; folder button next to + (left side); release 0.3.3.
- 2026-10-22: 0.3.3 released. Closing a chat must not shrink the panel (only collapse all does) → 0.3.4.
- 2026-10-22: BROWSE search found nothing: 'claude.ai error: timeout Runtime.evaluate' (catalog read capped at 8 s). Fix: 45 s for the catalog, 30 s per project, one automatic retry, the last list kept. Search covers the 300 most recent chats + every project.
- 2026-10-22: chat list must show from the start (even after a reboot); double-click the icon must open Claude even when closed; grey out + Reconnect (or automatic) when claude.ai is unreachable; [ADMIN] chat showed no earlier messages (critical) → 0.3.5.
- 2026-10-22: one chat open at a time (click its dot); right-click the dot opens it next to the others; Compact mode no longer a setting (always one line per chat). Added to 0.3.5 (not released yet).
- 2026-10-22: clicking the pinned panel (grip etc.) brings back the hidden taskbar (full-screen video) → the panel takes the focus only for typing / selecting. In 0.3.5.
- 2026-10-22: 0.3.5 released. Grip OK, but buttons (run a step...) still brought the taskbar back → check every button: 0.3.6 (no focus for any button, steps run with no window).
- 2026-10-24: chats / projects renamed on claude.ai kept their old names in the tray (titles were fixed at tracking time) → 0.3.7. Asked about other architectures: recommended reading claude.ai's own data instead of the page (option A), a compiled app later.
- 2026-10-25: BROWSE folds back on a click elsewhere; recent toggle (clock): chats active in 24 h not in the tray, greyed under the tracked ones, no heading; usable (open/read/reply), + keeps; off by default, remembered → 0.3.8.
- 2026-10-25: the link to the PC drops (Claude app closed or restarted: reboot this morning, app updated 3.1623 to 3.6556) → setting 'Keep the Claude app running' (started minimized, never over full screen). In 0.3.8.
- 2026-10-25: keep-app relaunch works (log 09:29). Subtle syncing mark for anything not loaded yet → in 0.3.8. Noted: each chat's 'this PC' link has to be set again in Claude (not the tray's).
- 2026-10-25: 0.3.8 released. A just-opened chat showed 'Tracked from the tray' instead of loading; ClaudeTray listed twice (tracked Code session + recent claude.ai chat) → 0.3.9.
- 2026-10-25: recent list took the whole panel (a comment had swallowed the 10-row limit and the sort) → fixed; 4 rows while a chat is open. In 0.3.9.
- 2026-10-25: recent chats only when all chats are collapsed; while one is open, only recent chats active right now (working mark), greyed; fainter rows. In 0.3.9.
- 2026-10-25: 0.3.9 released. Double-click: line opens, open chat closes (title or around messages; text keeps word selection) → 0.3.10.
- 2026-10-25: 0.3.10 released; README rewritten (every shortcut by topic, new images: code session, eBay research, permission, BROWSE, recent chats), published.
- 2026-10-25: icon showed "1 need you" with nothing to do (all steps done, 'check' not sent yet) → no longer counts; hollow dot in the panel. Working animation bigger on the icon (inside the ring) → 0.3.11.
- 2026-10-25: release step couldn't be run once a reply was sent (past round = read-only) → past undone steps get a run button with a confirm (second click, not a Windows popup: no focus steal); the skill re-issues undone steps in the next quest. In 0.3.11.
- 2026-10-25: 0.3.11 released (Run anyway worked: release ran from the earlier round). No running mark while it ran, looked frozen → animated 'running' mark → 0.3.12.
- 2026-10-25: older step lists disappeared from the conversation once Claude wrote a new one → kept (last 10, next to the results), shown above the message sent after them, run button greyed. In 0.3.12.
- 2026-10-25: 0.3.12 released. hero.png sent in a Code session: 'failed' in the tray (clicked, nothing downloaded in 40 s, no dialog) → look for a download control anywhere new after the click + log the new controls; still nothing ('...' forever). Page checked: the tile is data-testid=delivered-image-tile, img /api/<org>/files/<id>/preview; original at /api/organizations/<org>/files/<id>/contents → fetched directly → 0.3.13. Then the chip vanished after the tray restart: claude.ai doesn't draw delivered tiles after a reload → file ids kept by row (files.json), chips shown for unloaded messages too. In 0.3.13 (released, tested: opens, still there after a restart).
- 2026-10-25: bug button (GitHub issue page, prefilled; choice with / without the log - cleaned copy shown in its folder + clipboard, since a link can't attach a file); icon while working: only the dots, no usage ring → 0.3.14. LinkedIn drafts in a widget card didn't show in the tray → skill: text only.
