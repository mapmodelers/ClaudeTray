# Backlog

What's asked, planned and still open. Done work moves to [CHANGELOG.md](CHANGELOG.md).

## Now - 0.2.0

- **Compact mode** (setting). Its first part, validated on the mockup:
  - A collapsed chat takes one line: dot · field · bell · open in Claude · age.
  - **The dot** opens the conversation (16 px target, labelled).
  - **The field** shows the title.
    - Unread: bold, light grey. Read: grey. Never white.
    - Click: it empties and you type. /tray, attach and send appear inside the field; the icons to its right never move.
    - Enter sends. Esc, or clicking away with nothing typed, brings the title back.
    - A draft left unsent shows in italics in place of the title (title on hover).
  - Open chats stay as today.
- **Top bar**: the grip only, 8 px. Click = collapse / expand all; drag = move the panel; double-click does nothing
  (it used to go full screen).
- **Toolbar** (collapse/expand all · new chat · settings · pin), bottom left above usage. Menus open upward.
- **Hover labels on every icon.** Windows' own tooltips don't show because the panel never takes focus, so the page
  draws them (0.4 s), dots and step kinds included.
- **Claude Code questions** (the multiple-choice prompts) must show and be answerable in the tray: options, multi-select,
  "Other" text, submit.
  - Today they don't show at all, and a reply typed in the tray lands in the question's "Other" box (happened:
    "d" became an answer).
  - Approach: a generic extractor (radios, checkboxes, options, text box, submit) plus a structure-only diag to refine
    the selectors.
- **Files and images open in one click**: no Save-then-open-folder step.
  - A chip click downloads to temp and opens the file with its default app.
  - Images show as thumbnails in the conversation; a click opens them.

## Open questions

- Claude's last line after the title in the one-line row (dimmed after "·")?
- Compact mode: toolbar on the usage line (0 px, reset times on hover) or its own thin bar (+16 px)?
- Compact mode on by default?

## Later

- Watch the 0.1.5 skill offers (git, P4V / `p4`, builds) in real chats; tune the wording if Claude over- or under-asks.

## Log of requests

- 2026-10-20: thin toolbar at the bottom above usage; top bar clear (click = collapse / expand all).
- 2026-10-20: one-line collapsed chats → "Compact mode"; the dot opens the chat; titles never white.
- 2026-10-20: icons must all show a label on hover.
- 2026-10-20: Claude Code questions must show properly in the tray.
- 2026-10-20: images / files viewable without a download or open-folder step.
- 2026-10-20: keep track of everything said; backlog what doesn't fit one run.
