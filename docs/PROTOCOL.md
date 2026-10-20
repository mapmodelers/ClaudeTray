# ClaudeTray quest protocol (v1)

How a Claude chat and the tray talk: plain JSON files in one folder. Claude writes **quests**
(what it needs from you), the tray writes **results** (what happened when you ran them).

## Folder

One root, chosen by the user and known to both sides:

```
<root>\quests\<id>.json     written by Claude (via its device file access) at the end of a turn
<root>\results\<id>.json    written by the tray when you run a step / answer a question
```

Default root `%USERPROFILE%\ClaudeTray`. Claude can only write inside folders the chat has
connected, so the user may point both sides at a folder they always connect (see `config.json`
`questRoots`, and the path in the skill). `<id>` is the chat's claude.ai path with `/` → `__`,
e.g. `chat__1b2c3d4e-…` or `code__session_012…`.

## quest

```json
{
  "v": 1,
  "id": "code/session_0123456789abcdefABCDEF",
  "title": "[ClaudeTray]",
  "state": "act",
  "summary": "The new build is on disk - restart, then re-login.",
  "answer": "What I found / what to expect, in a few short lines.\nSecond line.",
  "updated": "2026-10-19T20:05:00+02:00",
  "reply": "check",
  "steps": [
    { "n": 1, "kind": "ps",      "label": "Restart on the new build", "cmd": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\...\\ClaudeTray.ps1\"" },
    { "n": 2, "kind": "ps",      "label": "Battery snapshot (admin)", "cmd": "...multi-line script...", "admin": true },
    { "n": 3, "kind": "exe",     "label": "build.cmd", "path": "C:\\proj\\build.cmd", "interactive": true },
    { "n": 4, "kind": "dir",     "label": "logs folder", "path": "C:\\proj\\logs" },
    { "n": 5, "kind": "url",     "label": "claude.ai usage", "url": "https://claude.ai/settings/usage" },
    { "n": 6, "kind": "observe", "label": "Did the screen dim?" },
    { "n": 7, "kind": "observe", "label": "Run git from the tray from now on?", "options": ["Yes", "No"] },
    { "n": 7, "kind": "manual",  "label": "Drag the icon out of the ^ area" }
  ]
}
```

| field | meaning |
| --- | --- |
| `id` | claude.ai path of the chat: `chat/<uuid>` or `code/<session_id>`. Open in app = `claude://claude.ai/<id>`, web = `https://claude.ai/<id>`. |
| `state` | `act` = steps for the user · `done` = Claude finished, nothing to run · (`working` is inferred by the tray: results newer than the quest, or a message just sent) |
| `summary` | one line, shown under the title |
| `answer` | optional, a few short lines (the gist of your reply; `\n` allowed) shown in a collapsible scrollable box - keep it tight |
| `reply` | text the field is prefilled with once steps are done (default `check`) |
| `steps[].kind` | `cmd` · `ps` (multi-line allowed, run hidden, output captured) · `exe` (run a file) · `dir` · `file` · `url` (open) · `observe` (one-line answer; `"options": ["Yes","No"]` = up to 4 buttons, the answer is the clicked text) · `manual` (tick) |
| `admin` | run elevated (one UAC prompt) · `interactive`: open a visible console instead of capturing |

Rewrite the whole file each turn (steps are replaced, not appended). Delete it, or set `state: done`
with no steps, when there is nothing left to do.

## results

```json
{
  "v": 1,
  "id": "code/session_0123456789abcdefABCDEF",
  "quest_updated": "2026-10-19T20:05:00+02:00",
  "steps": [
    { "n": 1, "status": "done", "exit": 0, "started": "…", "ended": "…", "out": "last 40 lines of stdout+stderr" },
    { "n": 3, "status": "done", "exit": 1, "out": "…" },
    { "n": 6, "status": "done", "answer": "yes, to about 40%" },
    { "n": 7, "status": "done" }
  ],
  "sent": [ { "at": "…", "text": "check" } ]
}
```

`quest_updated` tells Claude which version of the quest the results belong to. Steps not listed were
not run. `status: skipped` = the user right-clicked the step to postpone/ignore it - decide whether to drop it,
re-issue it, or do it yourself. When the user says "check" (or anything), Claude reads this file first, then the chat.

## Token cost

A quest is ~100–200 output tokens; the chat still gets the short numbered list it always had.
Results replace pasted logs, so a round trip costs less than today.

## Bridge mode (chats that can't reach the folder)

A claude.ai web chat (or any chat without the quest folder) can't write `quests\<id>.json`. With `/tray` on, Claude
then ends its reply with the same JSON, minified, in a fenced code block tagged `tray-quest`. The tray reads it from
the hidden browser tab (`$js` -> `quest`), forces `id` to the chat it came from, keeps known step kinds only, adds
`"bridge": true` and writes the quest file itself (`Poll-Bridge`); the panel hides the block. On the next message
sent from the panel for that quest version, the tray appends one results line instead of a results file Claude
can't read:

    [tray] 1 ✓ exit 0 | 2 ✓ "blue taskbar" | 3 ✗ exit 3: line1 / Access denied | 4 – | style terse

(✓ done, ✗ failed, – skipped; last two output lines only for failures; `style terse` when "Short replies" is on.)
