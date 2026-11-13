// The program's licence as a product: one declaration that the program (src/licence.odin) and its tool (ocntools'
// licence commands) both read.
package ocn_product

import licence "gt:licence"

// As the licence Worker and the tool's `licence` commands know it. `public_key` is empty until the maintainer makes the
// pair (`ocntools licence keygen`); `dev_public_key` is the toolkit's development pair, public on purpose (a debug build
// accepts its licences, a release never).
LICENCE :: licence.Product{
	name           = "opencode-native",
	title          = "opencode native",
	version_tag    = "OCN1",
	sign_context   = "opencode-native-licence-v1\n",
	file_extension = ".ocnlicence",
	public_key     = "",
	dev_public_key = "zHs7wxUEefqH37-vN5cKoTnZOCCFBnmcoQGrw6i3UAk",
	editions       = {0 = {id = "supporter", title = "Supporter"}, 1 = {id = "patron", title = "Patron"}},
}
