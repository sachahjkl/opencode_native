# Updates

From Wren's, with real channels. The client looks for a new version at start (`update.auto`) or from the palette ("Check
for updates"); nothing is installed before the user says so. Windows only for now: on Linux a new version is installed by hand.

| Channel | Reads | Gets |
|---|---|---|
| `stable` | `releases/latest/download/` | releases `vX.Y.Z` |
| `beta` | `releases/download/channel-beta/` (a rolling pre-release) | betas `vX.Y.Z-beta.N`, and every release |

Each channel publishes `update-windows-x64-<channel>.json`, its `.sig` and the program. The check (`src/update`, tested in
`src/update/update_test.odin`) refuses, in this order: a signature that is not the built-in key's (`SIGN_CONTEXT` + the
manifest's bytes, Ed25519; the manifest is read only once it is signed), another channel (it is in what is signed: a beta's
manifest served to stable is refused), another platform, a version that is not strictly newer, a file name that is not the
release's. After the download: the length, then the SHA-256 of the signed manifest. `update.base_url` moves where files are
read from, not what is trusted.

Putting it in place (`updater.odin`, `update_place`): written beside the program as `.update`, read back and checked, then the
running program renamed to `.old` and the new one to its name. If the second rename fails the first is undone. `.old` is
removed at the next start.

## The key

Ed25519, its own pair. Public half: `src/update/public_key.odin`. Private half: `secrets/production.yaml` (SOPS, age: `.sops.yaml`)
and the repository's secret `UPDATE_SIGNING_KEY`, which the release workflow signs with. Changing the key orphans every copy
already out: they would refuse what the new key signs.

    occtools update keygen <file outside the repository>
    occtools update manifest <exe> <version> <channel> <out.json>   (key: $UPDATE_SIGNING_KEY)
    occtools update verify <file.json> <channel>
