# Backlog

What's planned and still open. Done work is in [CHANGELOG.md](CHANGELOG.md). Ideas and feedback: [Discussions](https://github.com/mapmodelers/ClaudeTray/discussions).

## Now

- Questions: working from the tray in 0.2.5 (pick, Next, Back, several answers + Other, Send; "looks functional").
  Not tried yet: Other + Enter on a one-answer step, Skip, a question with a single step.
- Images: thumbnails in the conversation (today a click opens them).
- Model / effort change (0.3.0): confirm on a real claude.ai chat and a Claude Code session; the effort sub-menu opens on hover (a mouse move is sent).
- Desktop local chats: untested on the classic installer, multi-org, PowerShell 7, other UI languages.
- Left from the 0.3.1 UI review: Windows' own resize loop for the edges (only if they feel jittery); "Send answers" for a Desktop local chat's question (the tray ignores it today).
- Activity line: check on a live Claude Code run that the status words no longer show in the reply text (FR + EN).

## Decided

- Compact mode is a setting, off by default. In it, the dot opens a chat.
- Toolbar: its own thin bar above usage (not on the usage line).
- The one-line row shows Claude's last line after the title.

## Later

- Tray memory: confirm it stays flat over a long run with the app watcher off (0.3.21); the memory guard restarts it above 1.5 GB.

- Watch the 0.1.5 skill offers (git, other version control, builds) in real chats; tune the wording if Claude over- or under-asks.
