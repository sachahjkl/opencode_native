package ocntools

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import toolbox "gt:toolbox"

RUN_FOUND_TRIES :: 40
RUN_FOUND_WAIT  :: 3 * time.Second   // (GitHub says nothing of a run for some seconds: the only wait here, and it is theirs)
RELEASE_TRIES   :: 3
SITE_TRIES      :: 3
SITE_WAIT       :: 4 * time.Minute   // (the service says "try again later": what it needs, it has never said)
WATCH_INTERVAL  :: "20"

// What must hold before anything leaves. "": it does. The texts are those of the files, so that a test can give them.
not_ready :: proc(version, branch, setup, changelog, readme: string) -> string {
	if !version_is_valid(version) { return fmt.tprintf("%s is not a version", version) }
	if branch != fmt.tprintf("release/%s", version) { return fmt.tprintf("the branch is %s, not release/%s", branch, version) }
	if !strings.contains(setup, fmt.tprintf("APP_VERSION :: \"%s\"", version)) { return "src/setup.odin says another version" }
	if !strings.contains(changelog, fmt.tprintf("## [%s] - ", version)) { return "CHANGELOG.md has no section for it" }
	if !strings.contains(changelog, fmt.tprintf("[%s]: https://", version)) { return "CHANGELOG.md has no link for it" }
	if !strings.contains(readme, fmt.tprintf("badge/version-%s-", version)) { return "the README's badge says another version" }
	return ""
}

version_is_valid :: proc(v: string) -> bool {
	dots := 0
	last := '.'
	for c in v {
		switch c {
		case '.':
			if last == '.' { return false }
			dots += 1
		case '0' ..= '9':
		case:
			return false
		}
		last = c
	}
	return dots == 2 && last != '.'
}

// The id of the first run of `sha` in what `gh run list --json databaseId,headSha` says. 0: none.
run_of_sha :: proc(list, sha: string) -> i64 {
	Entry :: struct {
		databaseId: i64,
		headSha:    string,
	}
	entries: []Entry
	if json.unmarshal(transmute([]byte)list, &entries, allocator = context.temp_allocator) != nil { return 0 }
	for e in entries {
		if e.headSha == sha { return e.databaseId }
	}
	return 0
}

// The version in a manifest of an update.
manifest_version :: proc(text: string) -> string {
	Manifest :: struct {
		version: string,
	}
	m: Manifest
	if json.unmarshal(transmute([]byte)text, &m, allocator = context.temp_allocator) != nil { return "" }
	return m.version
}

@(private = "file")
find_run :: proc(workflow, sha: string) -> string {
	for _ in 0 ..< RUN_FOUND_TRIES {
		if list, code := toolbox.capture({"gh", "run", "list", "--workflow", workflow, "--limit", "10", "--json", "databaseId,headSha"}); code == 0 {
			if id := run_of_sha(list, sha); id != 0 { return fmt.tprint(id) }
		}
		time.sleep(RUN_FOUND_WAIT)
	}
	fmt.eprintfln("ship: no run of %s for %s", workflow, sha)
	return ""
}

@(private = "file")
watch :: proc(id: string) -> bool { return run("gh", "run", "watch", id, "--interval", WATCH_INTERVAL, "--exit-status") }

// A release may fail on a network that hiccups, and only that is tried again.
@(private = "file")
watch_release :: proc(id: string) -> bool {
	for try in 1 ..= RELEASE_TRIES {
		if watch(id) { return true }
		why, _ := toolbox.capture({"gh", "run", "view", id, "--log-failed"})
		if !network_hiccup(why) { return false }
		if try == RELEASE_TRIES || !run("gh", "run", "rerun", id, "--failed") { return false }
		time.sleep(RUN_FOUND_WAIT)
	}
	return false
}

// Whether a failed run's log says the network failed, not the build: a server's 5xx, or a name the runner could not resolve (its
// package mirror, apt's "Temporary failure resolving").
network_hiccup :: proc(log: string) -> bool {
	for words in ([]string{"error: 50", "returned error: 5", "Temporary failure resolving", "Could not resolve host"}) {
		if strings.contains(log, words) { return true }
	}
	return false
}

// The first run is master's own. Another is a new one: a run started again has two artifacts of the site, and is refused.
@(private = "file")
deploy_site :: proc(sha: string) -> bool {
	pages := find_run("pages.yml", sha)
	if pages != "" && watch(pages) { return true }
	for try in 2 ..= SITE_TRIES {
		time.sleep(SITE_WAIT)
		list, _ := toolbox.capture({"gh", "run", "list", "--workflow", "pages.yml", "--limit", "1", "--json", "databaseId,headSha"})
		last := run_of_sha(list, sha)
		if !run("gh", "workflow", "run", "pages.yml", "--ref", "master") { continue }
		for _ in 0 ..< RUN_FOUND_TRIES {
			time.sleep(RUN_FOUND_WAIT)
			now, _ := toolbox.capture({"gh", "run", "list", "--workflow", "pages.yml", "--limit", "1", "--json", "databaseId,headSha"})
			id := run_of_sha(now, sha)
			if id != 0 && id != last {
				if watch(fmt.tprint(id)) { return true }
				break
			}
		}
		fmt.eprintfln("ship: the site, try %d, failed", try)
	}
	return false
}

@(private = "file")
stop :: proc(what: string) -> int {
	fmt.eprintfln("ship: STOP, %s", what)
	return 1
}

run_ship :: proc(args: []string) -> int {
	version := ""
	dry := false
	for a in args {
		if a == "--dry-run" { dry = true } else if version == "" { version = a } else { fmt.eprintfln("ship: what is %s?", a); return EXIT_USAGE }
	}
	if version == "" { fmt.eprintln("ship <version> [--dry-run]"); return EXIT_USAGE }
	tag := fmt.tprintf("v%s", version)

	branch, _ := toolbox.capture({"git", "branch", "--show-current"})
	branch = strings.trim_space(branch)
	if why := not_ready(version, branch, read_text("src/setup.odin"), read_text("CHANGELOG.md"), read_text("README.md")); why != "" { return stop(why) }
	dirty, _ := toolbox.capture({"git", "status", "--porcelain"})
	if strings.trim_space(dirty) != "" { return stop("the tree has changes that are not committed") }
	if !run("git", "fetch", "-q", "origin") { return stop("no answer from origin") }
	if !run("git", "merge-base", "--is-ancestor", "origin/master", "HEAD") { return stop("origin/master moved: this branch does not follow it") }
	if _, code := toolbox.capture({"git", "rev-parse", "-q", "--verify", fmt.tprintf("refs/tags/%s", tag)}); code == 0 { return stop("the tag exists") }
	sha, _ := toolbox.capture({"git", "rev-parse", "HEAD"})
	sha = strings.trim_space(sha)
	base, _ := toolbox.capture({"git", "rev-parse", "origin/master"})
	base = strings.trim_space(base)
	fmt.printfln("ship: %s, commit %s, on master %s", version, sha[:7], base[:7])
	if dry { fmt.println("ship: ready, nothing done"); return 0 }

	if !run("git", "push", "-q", "-u", "origin", branch) { return stop("the branch was not pushed") }
	if !run("gh", "workflow", "run", "ci.yml", "--ref", branch) { return stop("CI did not start") }
	ci := find_run("ci.yml", sha)
	if ci == "" || !watch(ci) { return stop("CI is not green: no tag, master untouched") }

	if !run("git", "fetch", "-q", "origin") { return stop("no answer from origin") }
	now, _ := toolbox.capture({"git", "rev-parse", "origin/master"})
	if strings.trim_space(now) != base { return stop("origin/master moved during CI: no tag") }
	if !run("git", "tag", "-a", tag, "-m", fmt.tprintf("opencode native %s", version)) { return stop("no tag") }
	if !run("git", "push", "-q", "origin", tag) { return stop("the tag was not pushed") }
	release := find_run("release.yml", sha)
	if release == "" || !watch_release(release) { return stop("the release failed: master untouched") }

	if !run("git", "push", "-q", "origin", fmt.tprintf("%s^{{commit}}:refs/heads/master", tag)) { return stop("master was not pushed") }
	// (published: the site follows, what is left is tidying up, and a failure there undoes nothing)
	site := deploy_site(sha)
	if !site { fmt.eprintln("ship: published, but the site was not deployed: gh workflow run pages.yml --ref master, later") }
	ok := run("git", "push", "-q", "origin", "--delete", branch)
	ok = run("git", "fetch", "-q", "origin") && ok
	ok = run("git", "branch", "-f", "master", "origin/master") && ok
	ok = run("git", "switch", "-q", "master") && ok
	ok = run("git", "branch", "-d", branch) && ok

	stable, _ := toolbox.capture({"gh", "release", "download", tag, "--pattern", "update-windows-x64-stable.json", "--output", "-"})
	served := manifest_version(stable)
	fmt.printfln("ship: %s published, the stable manifest says %s", version, served)
	if served != version { return stop("the stable manifest does not say this version") }
	if !ok { fmt.eprintln("ship: published, but the local tidying up failed: see above") }
	return site && ok ? 0 : 1
}
