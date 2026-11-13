// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site); this file says what this site is: its address, names, colours, and its own check (the download each system's
// browser is offered).
//   ocntools site build <site> <out>       the two steps below, then the screenshots (docs/screenshots, in WebP) at the widths
//                                          the page shows them: <out> is what is published
//   ocntools site changelog <site> <out>   <out> gets a copy of <site>, the history, the classic pages and the shop's
//   ocntools site meta <site> <out>        what a page says when it is shared, the files around the pages
//   ocntools site card                     draws site/img/card.png, once, by hand
//   ocntools site check [--site folder] [--shot file.png] [--browser program]
//                                          the pages in a real browser, served on this machine, and the download of each system
// {{version}} in the home page is the last version: its download links name the files of that release, a download at once rather
// than a page of GitHub (the site is deployed when a release is: it cannot name a file not there yet).
package ocntools

import "core:fmt"
import "core:os"
import "core:strings"
import cdp "gt:cdp"
import toolbox "gt:toolbox"
import tk_site "gt:site"

SITE_DIR     :: "site"
SITE_CHANGES :: "CHANGELOG.md"
VERSION_MARK :: "{{version}}"

// Where the site is published, what it is: the one place that says it.
SITE_META :: tk_site.Meta{
	url         = "https://ocn.froment.software/",
	name        = "opencode native",
	repository  = "https://github.com/sachahjkl/opencode_native",
	tagline     = "An independent native client for the opencode server",
	changes     = SITE_CHANGES,
	card        = "img/card.png",
	logo        = "img/logo.png",
	logo_file   = "site/img/logo.png",
	theme       = "#111111",
	accent      = "#fab283",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareApplication",
	// On a domain of its own the site is what answers for /robots.txt and /favicon.ico. On github.io it is not.
	root_domain = false,
	card_title  = `<span>open</span>code <em>native</em>`,
	card_size   = 132,
	card_logo   = 168,
	card_font   = `"Segoe UI Variable Display", "Segoe UI", sans-serif`,
	publisher_logo = "img/froment-software-64.png",
	licence     = "MIT",
	footer_note = `Not affiliated with <a href="https://opencode.ai">OpenCode</a>`,
}

// The home page's download, one button per system the release builds for (the reader's shown; Windows when it is not known:
// a Mac or a phone, whoever reads the page there installs it on a computer).
@(rodata)
SITE_DOWNLOADS := [?]tk_site.Download{
	{os = "windows", label = "Windows", href = "https://github.com/sachahjkl/opencode_native/releases/download/v{{version}}/opencode-native-{{version}}-windows-x64.exe", detail = "v{{version}} · Windows 10 / 11 · x64 · .exe"},
	{os = "linux", label = "Linux", href = "https://github.com/sachahjkl/opencode_native/releases/download/v{{version}}/opencode-native-{{version}}-linux-x64.tar.gz", detail = "v{{version}} · x64 · .tar.gz · Vulkan"},
}

// What the home's structured data says besides its names.
SITE_LD :: [?][2]string{
	{"applicationCategory", "DeveloperApplication"},
	{"operatingSystem", "Windows, Linux"},
	{"license", "https://opensource.org/license/mit"},
}

// The screenshots at their width and at the two the page shows them at most (a gallery's column, the main column), each twice
// for a screen of twice the pixels. The logo, the sharing card and the maker's mark stay PNG: other sites read them.
SITE_IMAGE_WIDTHS :: [?]int{720, 1100}
SITE_IMAGE_KEEP   :: [?]string{"logo.png", "card.png", "froment-software-64.png"}

site_images :: proc() -> tk_site.Images_Options {
	widths, keep := SITE_IMAGE_WIDTHS, SITE_IMAGE_KEEP
	o := tk_site.Images_Options{dir = "img"}
	o.widths = make([]int, len(widths), context.temp_allocator)
	copy(o.widths, widths[:])
	o.keep = make([]string, len(keep), context.temp_allocator)
	copy(o.keep, keep[:])
	return o
}

// The screenshots, kept once in the repository (docs/screenshots, which the README shows too), in the published site's img.
// (conversation.webp is the README's alone.)
@(private = "file")
site_screenshots :: proc(out: string) -> bool {
	entries, err := os.read_all_directory_by_path(SHOTS_DOCS, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: no %s", SHOTS_DOCS); return false }
	for e in entries {
		if !strings.has_suffix(e.name, ".webp") || e.name == "conversation.webp" { continue }
		if os.copy_file(fmt.tprintf("%s/img/%s", out, e.name), fmt.tprintf("%s/%s", SHOTS_DOCS, e.name)) != nil {
			fmt.eprintfln("site: %s not copied", e.name)
			return false
		}
	}
	return true
}

site_meta :: proc() -> tk_site.Meta {
	m := SITE_META
	ld := SITE_LD
	m.ld_fields = make([][2]string, len(ld), context.temp_allocator)
	copy(m.ld_fields, ld[:])
	m.shop = SITE_SHOP
	return m
}

// The pages: the history, the classic pages and the shop's. (CHANGELOG.md is the repository's: main stands at its root.)
site_changelog :: proc(site, out: string, _: rawptr) -> bool {
	return tk_site.build_changelog(site, out, {changes = SITE_CHANGES, version_mark = VERSION_MARK, downloads = SITE_DOWNLOADS[:], meta = site_meta()})
}

// The shop's six pages (pricing, thanks, terms, refunds, privacy, imprint), made with the others (Meta.shop): "Coming soon"
// until Paddle's client token, the price id and the licence Worker are set here (docs/licence.md of the toolkit, "What the
// maintainer does at the end").
SITE_SHOP :: tk_site.Shop{
	name = "opencode native", icon = "../img/logo.png", product_title = "Opencode Native User License",
	price = "15&nbsp;&euro;", price_note = "", environment = "sandbox", edition = "supporter", price_id = "",
	thanks = "https://ocn.froment.software/thanks/", help = "https://github.com/sachahjkl/opencode_native/issues/new",
	register = "Open the file with opencode native, or paste the key in <em>Settings &rsaquo; Advanced &rsaquo; Licence</em>.",
	extension = ".ocnlicence", repository = "https://github.com/sachahjkl/opencode_native", seller = SELLER,
	code_licence = "MIT License", platform = "Windows 10 or 11, x64, and Linux, x64 (Vulkan). It works with an opencode server, on this computer or another.",
	network = "opencode native connects to your opencode server, on this computer unless you give another address. It asks GitHub for a new release when you turned on the automatic updates in the settings, or when you ask for it there, and puts an update in place only if it is signed by Froment Software.",
	stylesheet = "../style.css", home = "../", updated = "2026-11-13",
}

// The seller, as Wren's imprint names it: the same block in every program of Froment Software.
SELLER :: tk_site.Seller{
	name       = "Froment Software",
	owner      = "Sacha Froment",
	status     = "sole proprietor (<em>entrepreneur individuel</em>)",
	address    = "7 Lieu-dit les Renardi&egrave;res, 72220 Marign&eacute;-Laill&eacute;, France",
	email      = "contact@froment.software",
	url        = "https://froment.software",
	siren      = "131 941 718",
	siret      = "131 941 718 00010",
	ape        = "6201Z, computer programming",
	registry   = "the French national register of companies (RNE)",
	registered = "23 October 2026",
	vat        = "not applicable, article 293 B of the French General Tax Code (<em>franchise en base de TVA</em>)",
}

run_site :: proc(args: []string) -> int {
	what := len(args) > 0 ? args[0] : ""
	switch what {
	case "build", "changelog", "meta":
		if len(args) != 3 { break }
		site, out := args[1], args[2]
		if what == "changelog" { return site_changelog(site, out, nil) ? 0 : 1 }
		if what == "meta" { return tk_site.build_meta(site_meta(), site, out) ? 0 : 1 }
		if !site_changelog(site, out, nil) { return 1 }
		if !tk_site.build_meta(site_meta(), out, out) { return 1 }
		if !site_screenshots(out) { return 1 }
		o := site_images()
		why: string
		if o.encoder, why = toolbox.webp_encoder("build"); why != "" { fmt.eprintfln("site: no WebP encoder: %s", why); return 1 }
		return tk_site.build_images(out, o) ? 0 : 1
	case "card":
		if len(args) == 1 { return tk_site.draw_card(site_meta(), SITE_DIR) ? 0 : 1 }
	case "check":
		o := tk_site.Check_Options{site = SITE_DIR, generate = site_changelog, extra = site_downloads}
		if why := tk_site.check_arguments(args[1:], &o); why != "" { fmt.eprintfln("site check: %s", why); return EXIT_USAGE }
		return tk_site.check(o) ? 0 : 1
	}
	fmt.eprintln("site build|changelog|meta <site> <out> | card | check [--site folder] [--shot file.png] [--browser program]")
	return EXIT_USAGE
}

// A browser of each system: what it says it runs on (navigator.userAgent, navigator.platform, navigator.userAgentData), the
// download the home page offers it (the button: where, what it says, the file it says under that, the logo it shows; the small link
// to the other system's). A Mac and a phone get Windows's: whoever reads the page there installs it on a computer.
@(private = "file")
Site_System :: struct { name, agent, platform, data, button, label, sub, icon, other: string }

@(private = "file")
SITE_SYSTEMS :: [?]Site_System{
	{"Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Win32", "Windows", "-windows-x64.exe", "Download for Windows", " · Windows 10 / 11 · x64 · .exe", "windows", "-linux-x64.tar.gz"},
	{"Linux", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "Linux x86_64", "Linux", "-linux-x64.tar.gz", "Download for Linux", " · x64 · .tar.gz · Vulkan", "linux", "-windows-x64.exe"},
	{"macOS", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", "MacIntel", "macOS", "-windows-x64.exe", "Download for Windows", " · Windows 10 / 11 · x64 · .exe", "windows", "-linux-x64.tar.gz"},
	{"Android", "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36", "Linux armv8l", "Android", "-windows-x64.exe", "Download for Windows", " · Windows 10 / 11 · x64 · .exe", "windows", "-linux-x64.tar.gz"},
}

@(private = "file")
site_downloads :: proc(s: ^tk_site.Check) {
	systems := SITE_SYSTEMS
	for sys in systems {
		tk_site.check_call(s, "Emulation.setUserAgentOverride", fmt.tprintf(`{{"userAgent":%s,"platform":%s,"userAgentMetadata":{{"platform":%s,"platformVersion":"","architecture":"x86","model":"","mobile":false}}}}`,
			cdp.quote(sys.agent), cdp.quote(sys.platform), cdp.quote(sys.data)))
		if !tk_site.check_go(s, "index.html") { continue }
		// (the button and the line shown: those with a box; the toolkit's markup, tk_site download.odin)
		button :: `[...document.querySelectorAll('.hero [data-download-os]')].find((e) => e.getClientRects().length > 0)`
		other :: `[...document.querySelectorAll('.hero [data-download-others]')].find((e) => e.getClientRects().length > 0).querySelector('a')`
		main :: button + `.querySelector('.get-main').textContent`
		sub :: button + `.querySelector('.get-sub').textContent`
		icons :: `[...document.querySelectorAll('.hero [data-download-os]')].filter((e) => e.getClientRects().length > 0 && e.querySelector('.get-icon svg')).map((e) => e.dataset.downloadOs).join(',')`
		tk_site.check_expect(s, tk_site.check_true(s, fmt.tprintf(`%s.href.endsWith(%s) && %s === %s`, button, cdp.quote(sys.button), main, cdp.quote(sys.label))),
			fmt.tprintf("index.html, %s: the button is %s, %q (%s, %s)", sys.name, sys.button, sys.label, tk_site.check_text(s, button + ".href"), tk_site.check_text(s, main)))
		tk_site.check_expect(s, tk_site.check_true(s, fmt.tprintf(`%s.endsWith(%s) && /\d+\.\d+\.\d+/.test(%s)`, sub, cdp.quote(sys.sub), sub)),
			fmt.tprintf("index.html, %s: under it %q (%s)", sys.name, sys.sub, tk_site.check_text(s, sub)))
		tk_site.check_expect(s, tk_site.check_true(s, fmt.tprintf(`%s === %s`, icons, cdp.quote(sys.icon))),
			fmt.tprintf("index.html, %s: the logo %q (%s)", sys.name, sys.icon, tk_site.check_text(s, icons)))
		tk_site.check_expect(s, tk_site.check_true(s, fmt.tprintf(`%s.href.endsWith(%s)`, other, cdp.quote(sys.other))),
			fmt.tprintf("index.html, %s: the small link is %s (%s)", sys.name, sys.other, tk_site.check_text(s, other + ".href")))
	}
	tk_site.check_call(s, "Emulation.setUserAgentOverride", `{"userAgent":""}`)   // (the browser's own again)
}

