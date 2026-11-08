// What opencode native is to the toolkit's update package (gt:update, docs/updates.md): its name in the manifests and the release's
// file names, what its signatures cover, and the public half of its update key (occtools update keygen; the private half is in
// secrets/production.yaml and the release workflow's secret UPDATE_SIGNING_KEY). The program checks with it (updater.odin), the
// release tool signs with it (occtools update).
package occ_update

import update "gt:update"

PRODUCT :: update.Product{
	name         = "opencode-native",
	sign_context = "opencode-native-update-v1\n",
	public_key   = "5ViMkRP9j2Kg8brqGfooJlpsLPAZZu3uvtIkYH-WYCs",
}
