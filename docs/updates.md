# Updates

The toolkit's Updater (`gt:update`, its docs/update.md, "Channels"), as in every program of the toolkit (`src/updates.odin`).
With `update.auto` on, it looks for a new version a while after the start, then every day, and installs it: the new
program runs at the next start, or at once from "Restart now". The palette's "Check for updates" and the settings' Check
now ask at any time. The settings' Updates page is the toolkit's: `update.auto`, `update.channel` (Stable or Beta: followed
at once) and `update.base_url`, the state and the buttons under them. Windows and Linux. A Nix package (a program that
runs from `/nix/store`) never updates itself: Nix updates it.

| Channel | Reads | Gets |
|---|---|---|
| `stable` | `releases/latest/download/` | releases `vX.Y.Z` |
| `beta` | `releases/download/channel-beta/` (a rolling pre-release) | betas `vX.Y.Z-beta.N`, and every release |

Each channel publishes `update-<platform>-<channel>.json` (`windows-x64`, `linux-x64`), its `.sig` and the program: on Linux the
program alone, `opencode-native-<version>-linux-x64`, beside the archive. The check (`update.check_release` with
this program's `PRODUCT`, `src/update/product.odin`) refuses, in this order: a signature that is not the built-in key's (the
product's signing context + the manifest's bytes, Ed25519; the manifest is read only once it is signed), another channel (it is in what is signed: a beta's
manifest served to stable is refused), another platform, a version that is not strictly newer, a file name that is not the
release's. After the download: the length, then the SHA-256 of the signed manifest. `update.base_url`, a folder that holds
every channel's files, moves where they are read from, not what is trusted.

Putting it in place (`update.place`, called by the Updater): written beside the program as `.update`, read back and checked, then the
running program renamed to `.old` and the new one to its name. If the second rename fails the first is undone. `.old` is
removed at the next start (`update.remove_leftovers`). On Linux the new file is made executable and renamed over the program: the running process keeps
its open file.

## The key

Ed25519, its own pair. Public half: `PRODUCT.public_key` in `src/update/product.odin`. Private half: `secrets/production.yaml` (SOPS, age: `.sops.yaml`)
and the repository's secret `UPDATE_SIGNING_KEY`, which the release workflow signs with. Changing the key orphans every copy
already out: they would refuse what the new key signs.

The commands are the toolkit's (`toolbox.update_command`), as in every program:

    ocntools update keygen <file outside the repository>
    ocntools update pubkey                                          (key: $UPDATE_SIGNING_KEY)
    ocntools update manifest <exe> <version> <channel> <out.json>   (key: $UPDATE_SIGNING_KEY)
    ocntools update verify <file.json> <channel>
