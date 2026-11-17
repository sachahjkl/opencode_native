package ocn

import "core:testing"

// The licence card prints the program's logo on its front and raises it on its back, with the vendor's line under it:
// both come from the page's options (without them the card had a bare back and no logo).
@(test)
the_licence_card_has_the_logo_and_the_vendor :: proc(t: ^testing.T) {
	app: App
	o := licence_options(&app)
	testing.expect(t, len(o.logo) > 0 && string(o.logo) == string(LOGO_PNG), "the program's logo")
	testing.expect_value(t, o.vendor, "Froment Software")
}
