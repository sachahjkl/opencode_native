# opencode native: intent

The design of opencode native's parts, beside the code (https://srcmd.org). The code says how; these files say why: the
purpose, the decisions, what was refused.

- The interface is gui_toolkit's. What the toolkit decides is in its own `src/md`; these files record only what this
  program decides on top of it.

## File Index

- [features/views.md](features/views.md): the dialogs and the panels as views; the program's state as the truth of what
  is open; a shell's input in a window of its own; the Preview's page across windows.
- [features/missed.md](features/missed.md): several entries of What you missed selected and acknowledged at once.
- [features/job-reports.md](features/job-reports.md): the harness's reports of ended background jobs, read as cards.
