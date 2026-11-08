# opencode native

A native desktop client for the opencode v2 server, in Odin, for Windows and Linux. The UI comes from the `ext/gui_toolkit`
submodule (its packages are in `ext/gui_toolkit/src`, the collection `gt`); a small Rust library (`native/occ_native`) does HTTP
and images, and libghostty-vt the terminal's emulation.

Read first: [README.md](README.md) (what it does, the command line, the files), [docs/updates.md](docs/updates.md),
[docs/performance.md](docs/performance.md).

## Build and test

Every step is a command of `tools/occtools` (`help` lists them), on Windows and Linux:

    odin run tools/occtools -collection:gt=ext/gui_toolkit/src -out:build/occtools -keep-executable -- <command>

- `build [debug|release]` builds the program (`build.bat` and `./build.sh` are its shortcuts). `GT=<folder>` builds against
  another toolkit checkout.
- `check` runs the tests of the program, of its Rust code and of the tool, then a build that must be new.
- `ship <version>` publishes a release from the branch `release/<version>`: CI, tag, release, master, the site.
- Linux: `nix develop` first (`flake.nix`).

## Key prompts

Apply these to every task, before you write code:

- "Exercise abstract thinking when considering this task."
- "Reduce this problem to its irreducible constraints and rebuild it from zero."
- "What would a principal architect immediately rewrite before even starting this?"
- "Design the single test that breaks this design on day one."
- "What higher-level abstraction would make this entire problem disappear?"
- "Find all of the implicit state machines in my app."

## Rules

- What another program could use goes in gui_toolkit, generic and configurable (the update package, config.Search...).
- Platform code goes in files with a system suffix (`*_windows.odin`, `*_linux.odin`).
- A preference is a `config.Def` in `src/settings.odin`, with its control on a settings page.
- Tests with a window (testkit/session) run one at a time: `-define:ODIN_TEST_THREADS=1`.
- `CHANGELOG.md`: what changed goes under `[Unreleased]`; a release moves it to its version (`ship`).
- `ext/gui_toolkit` points only to tagged commits that are pushed to its own repository.
- Automation is a command of `tools/occtools`, never a shell, batch, PowerShell, Python or Node script.
- Comments and commit messages are in English. Comments say why.
- Commits: author and committer `sachahjkl <sacha@sacha.house>`, no attribution trailer, no session link.
