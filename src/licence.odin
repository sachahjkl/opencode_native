// The licence that supports the program (gt:licence): a signed key, checked here with no network. The program works the
// same without one. The settings show it on the toolkit's Licence page (prefs_page.Licence): its state, Buy a licence, a
// key to paste, a file to choose, Remove. Every read and write of its file is one of the page's tasks.
package ocn

import "core:fmt"
import prefs_page "gt:prefs_page"
import product "product"

// Where a licence is bought (the site's shop: "Coming soon" until it opens).
LICENCE_PRICING_URL :: "https://ocn.froment.software/pricing/"

// The store, beside the preferences, and its first read (a task). Not in a test: it has no preferences' file (the
// settings then show no Licence page).
licence_init :: proc(app: ^App) {
	if app.prefs_file == "" { return }
	prefs_page.licence_init(&app.licence, &app.state, {
		store = {product = product.LICENCE, path = pjoin({config_dir(), fmt.tprintf("licence%s", product.LICENCE.file_extension)}), accept_dev = ODIN_DEBUG},
		name = APP_NAME, pricing_url = LICENCE_PRICING_URL, owner = app.win,
	})
}

// The Licence page, when the store is open (nil: none, a test).
licence_page :: proc(app: ^App) -> ^prefs_page.Licence { return app.licence.store != nil ? &app.licence : nil }

// A licence file given (dropped, on the command line, chosen): installed rather than opened.
licence_install_file :: proc(app: ^App, path: string) {
	if app.licence.store != nil { prefs_page.licence_install_file(&app.licence, path) }
}
