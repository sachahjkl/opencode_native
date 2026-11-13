package ocntools

// The signed manifests of a release: the toolkit's command (toolbox.update_command, its docs/update.md) for this program's
// product (src/update), as in every program of the toolkit.
//   ocntools update keygen <file>                                  the update key pair; <file> is outside any git work tree
//   ocntools update pubkey                                         the public key of $UPDATE_SIGNING_KEY
//   ocntools update manifest <exe> <version> <channel> <out.json>  a manifest and its .sig, by $UPDATE_SIGNING_KEY
//   ocntools update verify <file.json> <channel>                   checks a manifest and its .sig with the built-in key

import toolbox "gt:toolbox"
import ocn_update "../../src/update"

run_update :: proc(args: []string) -> int { return toolbox.update_command(ocn_update.PRODUCT, args) }
