package ocntools

// The program's faces:
//   fonts_check <program>                       every font of assets/fonts is in the program, byte for byte (exit code 1 if one is not)
//   font_proposals [--only id[,id]] [--toolkit folder] [--exe file]
//                                               typefaces tried in the real client: the faces of each proposal (open licences, from
//                                               Fontsource) into build/font_proposals/<id>/fonts, and its pictures there (shots,
//                                               over --font-dir): nothing installed, nothing sent to the opencode server; what each
//                                               would add to the program

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

run_fonts_check :: proc(args: []string) -> int {
	if len(args) != 1 { fmt.eprintln("fonts_check <program>"); return EXIT_USAGE }
	program, err := os.read_entire_file(args[0], context.temp_allocator)
	if err != nil { fmt.eprintfln("fonts_check: cannot read %s", args[0]); return 1 }
	entries, derr := os.read_all_directory_by_path("assets/fonts", context.temp_allocator)
	if derr != nil { fmt.eprintln("fonts_check: no assets/fonts"); return 1 }
	missing := 0
	for e in entries {
		if !strings.has_suffix(e.name, ".ttf") { continue }
		face, ferr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if ferr != nil { missing += 1; continue }
		found := bytes.index(program, face) >= 0
		fmt.printfln("%s %s (%d KiB)", found ? "ok     " : "MISSING", e.name, (len(face) + 512) / 1024)
		if !found { missing += 1 }
	}
	return missing > 0 ? 1 : 0
}

// ui: the interface; prose: the answers, when it is another family; mono: code, paths and figures.
@(private = "file")
Proposal :: struct { id, ui, prose, mono: string, mono_bold: int }

@(private = "file")
PROPOSALS :: [?]Proposal{
	{id = "actuel"},
	{id = "etabli", ui = "ibm-plex-sans", mono = "ibm-plex-mono"},
	{id = "space", ui = "space-grotesk", mono = "space-mono"},
	{id = "chivo", ui = "chivo", mono = "chivo-mono"},
	{id = "lecture", ui = "hanken-grotesk", prose = "newsreader", mono = "dm-mono", mono_bold = 500},
	{id = "terminal", ui = "jetbrains-mono", mono = "jetbrains-mono"},
}

// A face of Fontsource into `file` (kept when it is there). Its size; 0 for an italic the family does not have (the upright serves).
@(private = "file")
fetch_face :: proc(family: string, weight: int, style, file: string) -> (size: int, ok: bool) {
	if data, err := os.read_entire_file(file, context.temp_allocator); err == nil { return len(data), true }
	url := fmt.tprintf("https://cdn.jsdelivr.net/fontsource/fonts/%s@latest/latin-%d-%s.ttf", family, weight, style)
	code, curl_code := toolbox.capture({"curl", "-sSL", "-o", file, "-w", "%{http_code}", url})
	if strings.trim_space(code) == "404" && style == "italic" { _ = os.remove(file); return 0, true }
	if curl_code != 0 || strings.trim_space(code) != "200" { _ = os.remove(file); fmt.eprintfln("%s: %s", url, code); return 0, false }
	data, err := os.read_entire_file(file, context.temp_allocator)
	return len(data), err == nil
}

run_font_proposals :: proc(args: []string) -> int {
	only, toolkit, exe := "", "", ""
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--only" && i + 1 < len(args):    i += 1; only = args[i]
		case args[i] == "--toolkit" && i + 1 < len(args): i += 1; toolkit = args[i]
		case args[i] == "--exe" && i + 1 < len(args):     i += 1; exe = args[i]
		case: fmt.eprintfln("font_proposals: what is %s?", args[i]); return EXIT_USAGE
		}
	}
	wanted := strings.split(only, ",", context.temp_allocator)
	proposals := PROPOSALS
	for p in proposals {
		if only != "" {
			listed := false
			for w in wanted { listed ||= w == p.id }
			if !listed { continue }
		}
		out := fmt.tprintf("build/font_proposals/%s", p.id)
		fonts := fmt.tprintf("%s/fonts", out)
		if !make_folder(fonts) { return 1 }
		total := 0
		if p.ui != "" {
			Role :: struct { name, family: string }
			roles := make([dynamic]Role, context.temp_allocator)
			append(&roles, Role{"ui", p.ui}, Role{"mono", p.mono})
			if p.prose != "" { append(&roles, Role{"prose", p.prose}) }
			for r in roles {
				bold := r.name == "mono" ? (p.mono_bold != 0 ? p.mono_bold : 700) : 600
				faces := [?]struct { weight: int, style, suffix: string }{{400, "normal", ""}, {bold, "normal", "-bold"}, {400, "italic", "-italic"}, {bold, "italic", "-bold-italic"}}
				for f, i in faces {
					if r.name == "mono" && i >= 2 { break }   // (code has no italic of its own here)
					size, ok := fetch_face(r.family, f.weight, f.style, fmt.tprintf("%s/%s%s.ttf", fonts, r.name, f.suffix))
					if !ok { return 1 }
					total += size
				}
			}
		}
		shots := make([dynamic]string, context.temp_allocator)
		append(&shots, "--out", out, "--only", "conversation,subagents,settings")
		if p.ui != "" { append(&shots, "--font-dir", fonts) }
		if toolkit != "" { append(&shots, "--toolkit", toolkit) }
		if exe != "" { append(&shots, "--exe", exe) }
		if run_shots(shots[:]) != 0 { return 1 }
		fmt.printfln("%s: %d KiB of faces (Latin only)", p.id, (total + 512) / 1024)
	}
	return 0
}
