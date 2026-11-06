package occtools

import "core:encoding/json"
import "core:strings"
import "core:testing"

SAMPLE_CHANGES :: `# Changelog

## [Unreleased]

- not yet

## [1.2.0] - 2026-11-06

What it is about.
Still the same paragraph.

### Added

- **A window**: of its own, with ` + "`code`" + `
  on two lines.
  - a sub-item
    that goes on
- Plain entry. Second sentence.

### Fixed

- One
- Two

## [1.1.0]

- Lost: no section, so no entry

## Notes

- nobody's

[1.2.0]: https://example.org/1.2.0
[1.1.0]: https://example.org/1.1.0
`

SAMPLE_HOME :: `<!doctype html>
<head>
<title>Thing</title>
<meta name="description" content="A thing.">
<link rel="icon" href="img/logo.png">
</head>
<header class="bar"><a class="brand" href="#">x</a>
<nav id="nav"><a href="#features">Features</a> <a href="changelog.html">Changelog</a></nav></header>
<section class="hero"><img class="mark" src="img/logo.png"><h1>The <em>thing</em></h1><p class="lead">It is.</p>
<div class="actions"><a class="btn" href="https://example.org/get">Get it</a></div><p class="small">MIT</p></section>
<figure class="shot wide"><a href="img/a.png">a</a></figure>
<section id="features" class="grid"><article class="card">
<h3>One thing</h3><p>First. Second.</p></article></section>
<!-- whats-new -->
<section class="gallery"><img src="img/b.png"></section>
<section id="download" class="download"><a href="#features">f</a></section>
<footer><p>Made.<br><a href="classic/">Classic version</a></p></footer>
<script>let a</script>
<script src="gallery.js" defer></script>
`

page_text :: proc(pages: []Page, path: string) -> string {
	for p in pages {
		if p.path == path { return p.text }
	}
	return ""
}

@(test)
what_is_escaped :: proc(t: ^testing.T) {
	testing.expect_value(t, esc(`a<b>&"c'`), "a&lt;b&gt;&amp;&quot;c'")
}

@(test)
inline_markup :: proc(t: ^testing.T) {
	testing.expect_value(t, inline("**bold** and `<code>`"), "<strong>bold</strong> and <code>&lt;code&gt;</code>")
	testing.expect_value(t, inline("[text](https://a.org/b) [no](ftp://a) [no](http:a b)"), `<a href="https://a.org/b">text</a> [no](ftp://a) [no](http:a b)`)
	testing.expect_value(t, inline("`**not bold**`"), "<code>**not bold**</code>")
	testing.expect_value(t, inline("** a ****b**"), "<strong> a </strong><strong>b</strong>")
	testing.expect_value(t, inline("****a**"), "<strong>**a</strong>")
	testing.expect_value(t, inline("``a`"), "`<code>a</code>")
	testing.expect_value(t, inline("**a\u2028b**"), "**a\u2028b**")
	testing.expect_value(t, inline("\x019\x02"), "undefined")
}

@(test)
what_js_calls_blank :: proc(t: ^testing.T) {
	testing.expect_value(t, js_trim("\u00a0\ufeff a\u3000\n"), "a")
	testing.expect_value(t, js_trim("\u200ba"), "\u200ba")
	testing.expect_value(t, plain_text("<b>a</b>\u00a0\n <i>b</i> <> c"), "a b <> c")
}

@(test)
a_js_string_counts_utf16 :: proc(t: ^testing.T) {
	testing.expect_value(t, utf16_length("a€😀"), 4)
	testing.expect_value(t, utf16_prefix("a😀b", 3), "a😀")
	testing.expect_value(t, utf16_prefix("a😀b", 2), "a\ufffd")
	testing.expect_value(t, utf16_prefix("ab", 5), "ab")
	testing.expect(t, utf16_less("\U0001F600", "\ue000"), "a surrogate comes before U+E000")
	testing.expect(t, utf16_less("a", "ab") && !utf16_less("ab", "a") && !utf16_less("a", "a"))
}

@(test)
dollars_in_a_replacement :: proc(t: ^testing.T) {
	testing.expect_value(t, replace_text("<x>", "x", "[$&]"), "<[x]>")
	testing.expect_value(t, replace_text("<x>", "x", "$`$'"), "<<>>")
	testing.expect_value(t, replace_text("<x>", "x", "$$ $1 $"), "<$ $1 $>")
}

@(test)
what_an_entry_is_about :: proc(t: ^testing.T) {
	testing.expect_value(t, lead("**Bold** and the rest"), "<strong>Bold</strong>")
	testing.expect_value(t, lead("One. Two"), "One.")
	testing.expect_value(t, lead("a.b c"), "a.b c")
	long := strings.repeat("x", LEAD_LONGEST + 1, context.temp_allocator)
	testing.expect_value(t, lead(long), cat(long[:LEAD_CUT], "…"))
	testing.expect_value(t, lead(long[:LEAD_LONGEST]), long[:LEAD_LONGEST])
}

@(test)
anchors_and_links :: proc(t: ^testing.T) {
	testing.expect_value(t, slug("  One, -- thing É! "), "one-thing")
	testing.expect_value(t, slug("---"), "")
	testing.expect_value(t, js_lower("ÉTÉ \u0130"), "été i\u0307")
	testing.expect_value(t, classic_link("#features"), FEATURES_PAGE)
	testing.expect_value(t, classic_link("#x"), "index.html#x")
	testing.expect_value(t, classic_link("#"), "index.html")
	testing.expect_value(t, classic_link("changelog.html#v1"), "changelog.html#v1")
	testing.expect_value(t, classic_link("img/a.png"), "../img/a.png")
	testing.expect_value(t, classic_link("MailTo:a"), "MailTo:a")
	testing.expect_value(t, classic_html(`<a href="img/a.png" data-src="b" xsrc="c">`), `<a href="../img/a.png" data-src="../b" xsrc="c">`)
	testing.expect_value(t, bar_for_page(`href="#" href="#a" href="#a b"`), `href="index.html" href="index.html#a" href="#a b"`)
	testing.expect_value(t, page_address("index.html"), SITE_URL)
	testing.expect_value(t, page_address("classic/index.html"), cat(SITE_URL, "classic/"))
	testing.expect_value(t, page_address("classic/xindex.html"), cat(SITE_URL, "classic/xindex.html"))
}

@(test)
what_is_taken_from_html :: proc(t: ^testing.T) {
	testing.expect_value(t, inner(" <h1>The <em>thing</em></h1>\n"), "The <em>thing</em>")
	testing.expect_value(t, between("a<b>c</b>d</b>", "<b>", "</b>"), "<b>c</b>")
	testing.expect_value(t, between("<b>c", "<b>", "</b>"), "")
	links := action_links(`<a class="x" href="a">A</a> <a href="b"><b>B</b></a>`)
	testing.expect_value(t, len(links), 2)
	testing.expect_value(t, links[1].label, "<b>B</b>")
}

@(test)
a_changelog_is_read :: proc(t: ^testing.T) {
	releases := parse_changelog(SAMPLE_CHANGES)
	testing.expect_value(t, len(releases), 2)
	r := releases[0]
	testing.expect_value(t, r.version, "1.2.0")
	testing.expect_value(t, r.date, "2026-11-06")
	testing.expect_value(t, r.link, "https://example.org/1.2.0")
	testing.expect_value(t, len(r.sections), 2)
	testing.expect_value(t, releases[1].date, "")
	all := entries(r)
	testing.expect_value(t, len(all), 4)
	testing.expect_value(t, all[0].text, "**A window**: of its own, with `code` on two lines.")
	testing.expect_value(t, all[0].subs[0], "a sub-item that goes on")
	testing.expect_value(t, render_blocks(blocks(r.intro[:])), "<p>What it is about. Still the same paragraph.</p>")
}

@(test)
crlf_is_the_same_changelog :: proc(t: ^testing.T) {
	crlf, _ := strings.replace_all(SAMPLE_CHANGES, "\n", "\r\n", context.temp_allocator)
	a := release_html(parse_changelog(SAMPLE_CHANGES)[0], true)
	b := release_html(parse_changelog(crlf)[0], true)
	testing.expect_value(t, a, b)
}

@(test)
the_feed_keeps_dated_versions :: proc(t: ^testing.T) {
	versions := feed_versions(SAMPLE_CHANGES)
	testing.expect_value(t, len(versions), 1)
	testing.expect_value(t, feed_body(versions[0].lines[:]), "<p>What it is about.</p><p>Still the same paragraph.</p><h3>Added</h3><ul><li><strong>A window</strong>: of its own, with <code>code</code> on two lines.</li><li>a sub-item that goes on</li><li>Plain entry. Second sentence.</li></ul><h3>Fixed</h3><ul><li>One</li><li>Two</li></ul>")
	testing.expect_value(t, heading_date(" - 2026-11-06 extra"), "2026-11-06")
	testing.expect_value(t, heading_date(" - 2026-1-1"), "")
	testing.expect_value(t, heading_date(" 2026-11-06"), "")
}

@(test)
the_pages_of_a_small_site :: proc(t: ^testing.T) {
	pages, why := make_pages(SAMPLE_HOME, parse_changelog(SAMPLE_CHANGES))
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(pages), 6)
	home := page_text(pages, SITE_HOME)
	testing.expect(t, strings.contains(home, `<section id="news" class="news">`) && !strings.contains(home, WHATS_NEW), "the news in place of the mark")
	testing.expect(t, strings.contains(home, "and 1 more</a>"), "what is not shown is counted")
	changelog := page_text(pages, CHANGELOG_PAGE)
	testing.expect(t, strings.contains(changelog, "<title>Changelog · Thing</title>"), "the page's title")
	testing.expect(t, strings.contains(changelog, `href="classic/changelog.html">Classic version`), "the footer goes to the classic page")
	testing.expect(t, strings.contains(changelog, `href="index.html#features"`), "the bar leads home")
	classic := page_text(pages, "classic/index.html")
	testing.expect(t, strings.contains(classic, `<li><a href="features.html#one-thing">One thing</a>: First</li>`), "a feature, in a line")
	testing.expect(t, strings.contains(classic, `<a href="features.html">features</a>`), "the nav is in lower case")
	testing.expect(t, strings.contains(classic, `<a href="../">Modern version</a>`), "the way back")
	testing.expect(t, strings.contains(page_text(pages, "classic/screenshots.html"), `<script src="../gallery.js" defer></script>`), "the viewer's script")
}

@(test)
a_home_page_without_its_parts_is_refused :: proc(t: ^testing.T) {
	releases := parse_changelog(SAMPLE_CHANGES)
	no_mark, _ := strings.replace_all(SAMPLE_HOME, WHATS_NEW, "", context.temp_allocator)
	_, why := make_pages(no_mark, releases)
	testing.expect(t, why != "", "no mark for the news")
	no_link, _ := strings.replace_all(SAMPLE_HOME, CLASSIC_LINK, "", context.temp_allocator)
	_, why = make_pages(no_link, releases)
	testing.expect(t, why != "", "no link to the classic pages")
	no_gallery, _ := strings.replace_all(SAMPLE_HOME, `class="gallery"`, "", context.temp_allocator)
	_, why = make_pages(no_gallery, releases)
	testing.expect(t, why != "", "no gallery")
}

@(test)
what_a_page_says_when_shared :: proc(t: ^testing.T) {
	html := `<title>A &amp; b</title><meta name="description" content="c"></head>`
	tags := page_tags(html, cat(SITE_URL, "a.html"), false)
	testing.expect(t, strings.contains(tags, `<meta property="og:title" content="A &amp; b">`), "its own title, already escaped")
	testing.expect(t, strings.contains(tags, `<meta property="og:type" content="article">`), "not the home")
	testing.expect(t, strings.contains(tags, `rel="canonical"`), "its address")
	testing.expect(t, !strings.contains(tags, "ld+json"), "no data")
	home := page_tags(`<link rel="canonical" href="x"></head>`, SITE_URL, true)
	testing.expect(t, strings.contains(home, cat(`content="`, SITE_NAME, `"`)), "no title: the site's name")
	testing.expect(t, !strings.contains(home, `rel="canonical"`), "one canonical is enough")
	testing.expect(t, strings.contains(home, "ld+json"), "the home's data")
	testing.expect(t, not_a_page(`<META NAME="robots" CONTENT="noindex">`), "noindex, in any case")
	testing.expect(t, not_a_page(`<meta http-equiv="Refresh" content="0">`), "a redirect")
	testing.expect(t, !not_a_page(`<title>noindex</title>`), "a page")
}

@(test)
the_json_files_are_json :: proc(t: ^testing.T) {
	for text in ([]string{structured_data(), web_manifest("1x1")}) {
		value, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		_, is_object := value.(json.Object)
		testing.expect(t, is_object)
	}
}

@(test)
the_address_is_said_once :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_suffix(SITE_URL, "/"), "the addresses are made by following it")
	testing.expect(t, strings.contains(sitemap_xml([]string{cat(SITE_URL, "b"), SITE_URL}), cat("<loc>", SITE_URL, "</loc></url>\n  <url><loc>", SITE_URL, "b</loc>")), "the sitemap is sorted")
	testing.expect(t, strings.contains(robots_txt(), cat(SITE_URL, "sitemap.xml")))
	testing.expect(t, strings.has_suffix(card_html("x"), "</p></main>"))
}
