---
name: tray
description: Activated by /tray in a chat (the user, or the ClaudeTray panel, starts a message with it). From then on in that chat, only when a reply ends with steps the user must do on their PC, also write them as a ClaudeTray quest file; on "check", read the tray's results file first. Do not apply in chats where /tray was not used.
---

# ClaudeTray quests (/tray)

Active only in chats where a message started with `/tray`, for the rest of that chat. The user runs **ClaudeTray**,
a Windows tray app that shows their Claude chats and runs the steps you give them with one click.
The tray can run, for the user, these actions: run a PowerShell / cmd command or script (hidden, output captured,
admin if needed), start a program, open a folder / file / web link, ask a one-line question, tick a manual step.
Use them **only when the user has to do something on their PC** - never for a reply that just answers.

**Root folder:** `<QUEST_ROOT>` (filled in by `ClaudeTray.ps1 -QuestRoot <folder>`, which writes
`skill\tray-personal.zip`). If this chat can't write there (a claude.ai web chat, no folder connected), use
**bridge mode**: put the same quest JSON, minified, in a fenced code block tagged `tray-quest` as the very last
thing of your reply. The tray reads it from the page, hides it and writes the file itself. Don't mention it.

## End of a turn with steps for the user

Keep the short numbered list in the chat, and overwrite `<root>\quests\<id>.json` (`<id>` = this chat's
claude.ai path with `/` → `__`: `code__session_…` or `chat__<uuid>`):

```json
{ "v": 1, "id": "code/session_…", "title": "<chat title>", "state": "act",
  "answer": "<1-2 short lines: the gist>", "updated": "<now, ISO 8601>", "reply": "check",
  "steps": [
    { "n": 1, "kind": "ps", "label": "<short label>", "cmd": "<exact command or script>" },
    { "n": 2, "kind": "observe", "label": "<question, one-line answer>" },
    { "n": 3, "kind": "manual", "label": "<thing to do by hand>" }
  ] }
```

Kinds: `cmd`/`ps` (run hidden, output captured) · `exe` · `dir` · `file` · `url` (open) · `observe` ·
`manual`. Add `"admin": true` for elevation, `"interactive": true` when it prompts. Omit false/empty fields.

End of a turn with **nothing** to run: write nothing (the tray sees you finished).

## When the user says "check" (or reports back)

Read `<root>\results\<id>.json` first: per step `status` (`done`/`failed`/`skipped` = postponed by the user),
`exit`, the last lines of output (`out`, already trimmed) and one-line `answer`s. Use it instead of asking
the user to paste anything. Missing or `quest_updated` ≠ your quest → use the chat. In bridge mode the
user's message ends with a `[tray]` line instead: `n ✓/✗/– exit / "answer" / last output` per step.
If it has `"style": "terse"` (bridge mode: `style terse` in the `[tray]` line): from then on write every reply in this chat as short as possible -
telegraphic, abbreviations and shortcuts OK, no recap, no politeness, typos don't matter.

## Keep it cheap

- The quest costs ~100-200 output tokens: no extra prose in it, no narration about writing it.
- `answer` = 1-2 lines (the tray also shows your full reply live). Labels under ~40 characters.
- Read the results file only on "check"; never re-read your own quest.
- Steps stand alone (full paths). Never put secrets in either file.
