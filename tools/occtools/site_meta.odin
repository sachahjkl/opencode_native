// What a page says when it is shared, and the files around the pages. Every page of <out> (a copy of <site>, or <site> itself)
// gets its canonical address, Open Graph and Twitter tags, from its own title and description; the home page its structured data.
// A redirect or a page marked noindex is left alone. Writes feed.xml (Atom, from CHANGELOG.md), sitemap.xml, site.webmanifest,
// llms.txt and a 404.html if there is none. The sharing card, site/img/card.png, is drawn once and kept in the repository.
package occtools

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Where the site is published: the one place that says it.
SITE_URL :: "https://ocn.froment.software/"

SITE_NAME        :: "opencode native"
SITE_REPOSITORY  :: "https://github.com/sachahjkl/opencode_native"
SITE_TAGLINE     :: "An independent native client for the opencode server"
SITE_CARD        :: "img/card.png"
SITE_LOGO        :: "img/logo.png"
SITE_LOGO_FILE   :: "site/img/logo.png"
SITE_THEME       :: "#111111"
SITE_ACCENT      :: "#fab283"
SITE_AUTHOR      :: "Sacha Froment"
SITE_AUTHOR_URL  :: "https://froment.software"
SITE_PUBLISHER   :: "Froment Software"
// On a domain of its own the site is what answers for /robots.txt and /favicon.ico. On github.io it is not.
SITE_ROOT_DOMAIN :: false
SITE_ICO         :: ""

SITE_NOT_LISTED  :: "404.html"
FEED_FILE        :: "feed.xml"
FEED_VERSIONS    :: 30
FEED_DATE_LENGTH :: len("2026-11-06")
PNG_WIDTH_AT     :: 16
PNG_HEIGHT_AT    :: 20

CARD_TITLE       :: `<span>open</span>code <em>native</em>`
CARD_TITLE_SIZE  :: "132"
CARD_LOGO_SIZE   :: "168"
CARD_FONT        :: `"Segoe UI Variable Display", "Segoe UI", sans-serif`
CARD_BROWSERS    :: [?]string{
	"C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
	"C:/Program Files/Google/Chrome/Application/chrome.exe",
	"/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser",
}

// file:// for a path, what a browser opens.
file_url :: proc(path: string) -> string {
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil { abs = path }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	if !strings.has_prefix(abs, "/") && !strings.has_prefix(abs, "\\") { strings.write_byte(&b, '/') }
	for i in 0 ..< len(abs) {
		c := abs[i]
		switch {
		case c == '\\':
			strings.write_byte(&b, '/')
		case is_word_byte(c), strings.index_byte("/:.-~", c) >= 0:
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

card_html :: proc(logo_url: string) -> string {
	return cat(`<!doctype html><meta charset="utf-8"><style>

html, body { margin: 0; width: 1200px; height: 630px; overflow: hidden; background: #111; color: #f2f2f2; }
main { box-sizing: border-box; width: 1200px; height: 630px; padding: 0 72px 68px; display: flex; flex-direction: column; justify-content: flex-end;
  font-family: `, CARD_FONT, `; }
img { display: block; width: `, CARD_LOGO_SIZE, `px; height: `, CARD_LOGO_SIZE, `px; margin: 0 0 18px -6px; }
h1 { margin: 0; font-size: `, CARD_TITLE_SIZE, `px; line-height: 1.02; font-weight: 700; letter-spacing: -0.035em; }
h1 span { color: #8a8a8a; } h1 em { font-style: normal; color: `, SITE_ACCENT, `; }
p { margin: 22px 0 0; font-size: 42px; line-height: 1.2; font-weight: 400; color: #a3a3a3; }
</style><main><img src="`, logo_url, `" alt=""><h1>`, CARD_TITLE, "</h1><p>", SITE_TAGLINE, "</p></main>")
}

// The card, in a local Chromium, once: the site only carries the picture. It is one call with no page to drive, so no DevTools.
site_card :: proc() -> int {
	browser := os.get_env("CHROME", context.temp_allocator)
	if browser == "" || !os.exists(browser) {
		browser = ""
		browsers := CARD_BROWSERS
		for b in browsers {
			if os.exists(b) { browser = b; break }
		}
	}
	if browser == "" { fmt.eprintln("site: no Chromium found: set CHROME"); return EXIT_USAGE }
	dir, err := os.make_directory_temp("", "site-card-*", context.temp_allocator)
	if err != nil { fmt.eprintfln("site: no temporary folder: %v", err); return 1 }
	defer os.remove_all(dir)
	page := cat(dir, "/card.html")
	picture := cat(dir, "/out.png")
	if !write_text(page, card_html(file_url(SITE_LOGO_FILE))) { return 1 }
	_, drawn := capture(browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files", cat("--user-data-dir=", dir, "/profile"),
		"--virtual-time-budget=5000", "--force-device-scale-factor=1", "--window-size=1200,630", cat("--screenshot=", picture), file_url(page))
	if !drawn { fmt.eprintfln("site: %s drew nothing", browser); return 1 }
	if copy_err := os.copy_file(cat("site/", SITE_CARD), picture); copy_err != nil { fmt.eprintfln("site: site/%s: %v", SITE_CARD, copy_err); return 1 }
	fmt.printfln("site/%s", SITE_CARD)
	return 0
}

Feed_Version :: struct {
	version, date: string,
	lines:         [dynamic]string,
}

// /(?: - (\d{4}-\d{2}-\d{2}))?/ after a version: a heading with no date is no version of the feed.
heading_date :: proc(rest: string) -> string {
	if !strings.has_prefix(rest, " - ") || len(rest) < len(" - ") + FEED_DATE_LENGTH { return "" }
	date := rest[len(" - "):][:FEED_DATE_LENGTH]
	for i in 0 ..< len(date) {
		dash := i == 4 || i == 7
		if dash ? date[i] != '-' : !(date[i] >= '0' && date[i] <= '9') { return "" }
	}
	return date
}

// CHANGELOG.md: "## [x.y.z] - date", then its text.
feed_versions :: proc(text: string) -> []^Feed_Version {
	out := make([dynamic]^Feed_Version, context.temp_allocator)
	r: ^Feed_Version
	for l in split_lines(text) {
		if version, rest, ok := version_heading(l); ok {
			r = nil
			if date := heading_date(rest); date != "" {
				r = new(Feed_Version, context.temp_allocator)
				r.version, r.date = version, date
				r.lines = make([dynamic]string, context.temp_allocator)
				append(&out, r)
			}
			continue
		}
		_, after, bracketed := bracket(l)
		if strings.has_prefix(l, "## ") || (bracketed && strings.has_prefix(after, ":")) { r = nil; continue }
		if r != nil { append(&r.lines, l) }
	}
	return out[:]
}

// Where /<li>.*?<\/li>/ at `at` ends. -1: it is not there.
list_item_end :: proc(s: string, at: int) -> int {
	if !strings.has_prefix(s[at:], "<li>") { return -1 }
	body := at + len("<li>")
	close := strings.index(s[body:], "</li>")
	if close < 0 || has_line_end(s[body:body + close]) { return -1 }
	return body + close + len("</li>")
}

// A version's text as HTML: its headings and its entries, an entry possibly on several lines.
feed_body :: proc(lines: []string) -> string {
	flat := strings.builder_make(context.temp_allocator)
	item := ""
	has_item := false
	flush :: proc(b: ^strings.Builder, item: string, has_item: ^bool) {
		if has_item^ { put(b, "<li>", inline(item), "</li>") }
		has_item^ = false
	}
	for raw in lines {
		l := js_trim(raw)
		if name, ok := section_line(l); ok {
			flush(&flat, item, &has_item)
			put(&flat, "<h3>", esc(name), "</h3>")
		} else if strings.has_prefix(l, "- ") && !has_line_end(l) {
			flush(&flat, item, &has_item)
			item, has_item = l[len("- "):], true
		} else if l == "" {
			flush(&flat, item, &has_item)
		} else if has_item {
			item = cat(item, " ", l)
		} else {
			put(&flat, "<p>", inline(l), "</p>")
		}
	}
	flush(&flat, item, &has_item)

	s := strings.to_string(flat)
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		end := list_item_end(s, i)
		if end < 0 {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		for {
			next := list_item_end(s, end)
			if next < 0 { break }
			end = next
		}
		put(&b, "<ul>", s[i:end], "</ul>")
		i = end
	}
	return strings.to_string(b)
}

feed_xml :: proc(rs: []^Feed_Version) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>`, SITE_URL, `</id>
  <title>`, esc(SITE_NAME), `: releases</title>
  <subtitle>`, esc(SITE_TAGLINE), `</subtitle>
  <link rel="self" type="application/atom+xml" href="`, SITE_URL, FEED_FILE, `"/>
  <link rel="alternate" type="text/html" href="`, SITE_URL, `"/>
  <icon>`, SITE_URL, SITE_LOGO, `</icon>
  <author><name>`, SITE_AUTHOR, `</name><uri>`, SITE_AUTHOR_URL, `</uri></author>
  <updated>`, rs[0].date, "T00:00:00Z</updated>\n")
	for r, i in rs {
		if i > 0 { strings.write_byte(&b, '\n') }
		address := cat(SITE_URL, CHANGELOG_PAGE, "#v", r.version)
		put(&b, `  <entry>
    <id>`, address, `</id>
    <title>`, esc(SITE_NAME), " ", esc(r.version), `</title>
    <link rel="alternate" type="text/html" href="`, address, `"/>
    <updated>`, r.date, `T00:00:00Z</updated>
    <content type="html">`, esc(feed_body(r.lines[:])), `</content>
  </entry>`)
	}
	strings.write_string(&b, "\n</feed>\n")
	return strings.to_string(b)
}

// JSON.stringify(..., null, 2) of the home's data: the values are the constants above, none has anything to escape.
structured_data :: proc() -> string {
	return `{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "` + SITE_NAME + `",
  "description": "` + SITE_TAGLINE + `",
  "url": "` + SITE_URL + `",
  "image": "` + SITE_URL + SITE_CARD + `",
  "applicationCategory": "DeveloperApplication",
  "operatingSystem": "Windows, Linux",
  "license": "https://opensource.org/license/mit",
  "author": {
    "@type": "Person",
    "name": "` + SITE_AUTHOR + `",
    "url": "` + SITE_AUTHOR_URL + `"
  },
  "publisher": {
    "@type": "Organization",
    "name": "` + SITE_PUBLISHER + `",
    "url": "` + SITE_AUTHOR_URL + `"
  }
}`
}

web_manifest :: proc(logo_size: string) -> string {
	return cat(`{
  "name": "`, SITE_NAME, `",
  "short_name": "`, SITE_NAME, `",
  "description": "`, SITE_TAGLINE, `",
  "lang": "en",
  "start_url": "./",
  "scope": "./",
  "display": "browser",
  "background_color": "`, SITE_THEME, `",
  "theme_color": "`, SITE_THEME, `",
  "icons": [
    {
      "src": "`, SITE_LOGO, `",
      "sizes": "`, logo_size, `",
      "type": "image/png"
    }
  ]
}
`)
}

// What goes before a page's </head>. The title and the description are the page's own, already escaped.
page_tags :: proc(html, address: string, home: bool) -> string {
	title := SITE_NAME
	if at, end, ok := title_span(html); ok { title = html[at + len("<title>"):end - len("</title>")] }
	description, described := quoted_value(html, `<meta name="description" content="`, "")
	if !described { description = esc(SITE_TAGLINE) }
	alt := esc(cat(SITE_NAME, ": ", SITE_TAGLINE))
	image := cat(SITE_URL, SITE_CARD)
	b := strings.builder_make(context.temp_allocator)
	if !strings.contains(html, `rel="canonical"`) { put(&b, `<link rel="canonical" href="`, address, "\">\n") }
	put(&b, `<meta name="author" content="`, SITE_AUTHOR, `">
<meta name="theme-color" content="`, SITE_THEME, `">
<link rel="alternate" type="application/atom+xml" title="`, esc(SITE_NAME), `: releases" href="`, SITE_URL, FEED_FILE, `">
<link rel="apple-touch-icon" href="`, SITE_URL, SITE_LOGO, `">
<link rel="manifest" href="`, SITE_URL, `site.webmanifest">
<meta property="og:type" content="`, home ? "website" : "article", `">
<meta property="og:site_name" content="`, esc(SITE_NAME), `">
<meta property="og:locale" content="en_US">
<meta property="og:title" content="`, title, `">
<meta property="og:description" content="`, description, `">
<meta property="og:url" content="`, address, `">
<meta property="og:image" content="`, image, `">
<meta property="og:image:secure_url" content="`, image, `">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="`, alt, `">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="`, title, `">
<meta name="twitter:description" content="`, description, `">
<meta name="twitter:image" content="`, image, `">
<meta name="twitter:image:alt" content="`, alt, `">`)
	if home { put(&b, "\n<script type=\"application/ld+json\">\n", structured_data(), "\n</script>") }
	return strings.to_string(b)
}

// A redirect or a page marked noindex: /<meta name="robots" content="noindex|http-equiv="refresh"/i
not_a_page :: proc(html: string) -> bool {
	lower := strings.to_lower(html, context.temp_allocator)
	return strings.contains(lower, `<meta name="robots" content="noindex`) || strings.contains(lower, `http-equiv="refresh"`)
}

// The address of a page of the site: a folder for its index.html.
page_address :: proc(page: string) -> string {
	if page == SITE_HOME { return SITE_URL }
	if strings.has_suffix(page, cat("/", SITE_HOME)) { return cat(SITE_URL, page[:len(page) - len(SITE_HOME)]) }
	return cat(SITE_URL, page)
}

// sort() compares UTF-16 units: past U+FFFF a character is a surrogate, which comes before U+E000 and what follows it.
utf16_less :: proc(a, b: string) -> bool {
	unit :: proc(r: rune) -> rune { return r >= 0x10000 ? 0xD800 + (r - 0x10000) >> 10 : r }
	x, y := a, b
	for x != "" && y != "" {
		r, r_width := utf8.decode_rune_in_string(x)
		o, o_width := utf8.decode_rune_in_string(y)
		if r != o { return unit(r) != unit(o) ? unit(r) < unit(o) : r < o }
		x, y = x[r_width:], y[o_width:]
	}
	return x == "" && y != ""
}

// Every .html of a folder but the 404, as paths of the site.
html_pages :: proc(root: string) -> (pages: []string, ok: bool) {
	abs, err := os.get_absolute_path(root, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", root, err); return nil, false }
	out := make([dynamic]string, context.temp_allocator)
	w: os.Walker
	os.walker_init_path(&w, abs)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if path, walk_err := os.walker_error(&w); walk_err != nil { fmt.eprintfln("site: %s: %v", path, walk_err); return nil, false }
		if info.type == .Directory { continue }
		// (the walker's path lasts until its next step)
		page := strings.clone(info.fullpath[len(abs) + 1:], context.temp_allocator)
		page, _ = strings.replace_all(page, "\\", "/", context.temp_allocator)
		if strings.has_suffix(page, ".html") && page != SITE_NOT_LISTED { append(&out, page) }
	}
	return out[:], true
}

sitemap_xml :: proc(listed: []string) -> string {
	sorted := slice.clone(listed, context.temp_allocator)
	slice.sort_by(sorted, utf16_less)
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
`)
	for a, i in sorted {
		if i > 0 { strings.write_byte(&b, '\n') }
		put(&b, "  <url><loc>", a, "</loc></url>")
	}
	strings.write_string(&b, "\n</urlset>\n")
	return strings.to_string(b)
}

llms_txt :: proc() -> string {
	return cat("# ", SITE_NAME, "\n\n> ", SITE_TAGLINE, "\n\n## Pages\n\n- [", SITE_NAME, "](", SITE_URL, "): the home page.\n- [Changelog](", SITE_URL, CHANGELOG_PAGE,
		"): every version.\n- [Releases feed](", SITE_URL, FEED_FILE, "): new versions, in Atom.\n- [Source](", SITE_REPOSITORY, "): the repository.\n")
}

not_found_html :: proc() -> string {
	return cat(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<meta name="color-scheme" content="dark">
<title>Not found · `, esc(SITE_NAME), `</title>
<link rel="icon" href="`, SITE_URL, SITE_LOGO, `">
<style>
html { background: `, SITE_THEME, `; color: #e6e6e6; font: 18px/1.5 system-ui, sans-serif; }
body { margin: 18vh auto 0; padding: 0 24px; max-width: 34rem; }
img { display: block; width: 72px; height: 72px; }
h1 { margin: 20px 0 8px; font-size: 2.2rem; }
a { color: `, SITE_ACCENT, `; }
</style>
</head>
<body>
<img src="`, SITE_URL, SITE_LOGO, `" alt="">
<h1>Not found</h1>
<p>This page does not exist. <a href="`, SITE_URL, `">`, esc(SITE_NAME), `</a></p>
</body>
</html>
`)
}

robots_txt :: proc() -> string { return cat("User-agent: *\nAllow: /\n\nSitemap: ", SITE_URL, "sitemap.xml\n") }

png_size :: proc(path: string) -> (size: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err); return "", false }
	if len(data) < PNG_HEIGHT_AT + size_of(u32) { fmt.eprintfln("site: %s is no PNG", path); return "", false }
	width, _ := endian.get_u32(data[PNG_WIDTH_AT:], .Big)
	height, _ := endian.get_u32(data[PNG_HEIGHT_AT:], .Big)
	return fmt.tprintf("%dx%d", width, height), true
}

same_folder :: proc(a, b: string) -> bool {
	x, x_err := os.get_absolute_path(a, context.temp_allocator)
	y, y_err := os.get_absolute_path(b, context.temp_allocator)
	return x_err == nil && y_err == nil && strings.trim_right(x, "/\\") == strings.trim_right(y, "/\\")
}

site_meta :: proc(from, out: string) -> int {
	if !same_folder(from, out) && !copy_site(from, out) { return 1 }
	if !os.exists(cat(out, "/", SITE_CARD)) { fmt.eprintfln("site: no %s: occtools site card", SITE_CARD); return 1 }

	pages, found := html_pages(out)
	if !found { return 1 }
	listed := make([dynamic]string, context.temp_allocator)
	for page in pages {
		path := cat(out, "/", page)
		html, readable := read_utf8(path)
		if !readable { return 1 }
		head := strings.index(html, "</head>")
		if head < 0 || not_a_page(html) { continue }
		address := page_address(page)
		if !write_text(path, cat(html[:head], page_tags(html, address, page == SITE_HOME), "\n", html[head:])) { return 1 }
		append(&listed, address)
	}

	changes, has_changes := read_utf8(SITE_CHANGES)
	if !has_changes { return 1 }
	rs := feed_versions(changes)
	if len(rs) == 0 { fmt.eprintfln("site: no version in %s", SITE_CHANGES); return 1 }
	logo_size, has_logo := png_size(cat(out, "/", SITE_LOGO))
	if !has_logo { return 1 }
	shown := rs[:min(FEED_VERSIONS, len(rs))]
	if !write_text(cat(out, "/", FEED_FILE), feed_xml(shown)) { return 1 }
	if !write_text(cat(out, "/sitemap.xml"), sitemap_xml(listed[:])) { return 1 }
	if !write_text(cat(out, "/site.webmanifest"), web_manifest(logo_size)) { return 1 }
	if !write_text(cat(out, "/llms.txt"), llms_txt()) { return 1 }
	if !os.exists(cat(out, "/", SITE_NOT_LISTED)) && !write_text(cat(out, "/", SITE_NOT_LISTED), not_found_html()) { return 1 }
	if SITE_ROOT_DOMAIN {
		if !write_text(cat(out, "/robots.txt"), robots_txt()) { return 1 }
		if SITE_ICO != "" {
			if err := os.copy_file(cat(out, "/favicon.ico"), SITE_ICO); err != nil { fmt.eprintfln("site: %s: %v", SITE_ICO, err); return 1 }
		}
	}
	fmt.printfln("%d pages, %d versions in the feed: %s", len(listed), len(shown), out)
	return 0
}
