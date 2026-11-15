# Setup: the toolkit's screen with opencode native's content

The install's screen, the settings' Installation page and `--install`, `--uninstall`, `--status`, `--quit`, `--setup`
are gt:setup's, held by `prefs_page.Install` (`app.install`). The program gives only its content, through
`setup_options` (desktop.odin) and the `Install` fields:

- its identity: the name, and the description the screen shows under it (it says the project is not the OpenCode
  team's);
- its logo, painted in the accent (setup.odin `logo_load`, also the title bar's), passed each frame by `setup_frame`;
- its vendor: `Identity.vendor`, `Setup_Options.vendor_url` (the vendor's site) and `Install.vendor_mark` (the site's
  mark, `site/img/froment-software-64.png`): the screen's "By" line;
- its backdrop (the window blurred behind it as a dialog) and what an install does besides the toolkit's parts
  (`setup_prepare`: the record of the Setup before 0.20 goes).

## Decisions

- **No note.** `Setup_Options.note` stays empty: the new screen does not show it, and the description already says
  that the project is independent. The same fact twice on one screen is refused.
- **No screen of the program's own.** A program draws its own only for another layout (`setup.start`); opencode native
  needs none.
