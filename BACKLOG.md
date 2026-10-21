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
