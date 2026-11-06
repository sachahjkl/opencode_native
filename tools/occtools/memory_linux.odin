package occtools

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// What a process holds, in bytes: in physical memory, and of its own.
memory_of :: proc(p: os.Process) -> (working, private: u64) {
	text := read_text(fmt.tprintf("/proc/%d/status", p.pid))
	field :: proc(text, name: string) -> u64 {
		at := strings.index(text, name)
		if at < 0 { return 0 }
		line := text[at + len(name):]
		fields := strings.fields(line[:max(strings.index(line, "\n"), 0)], context.temp_allocator)
		if len(fields) == 0 { return 0 }
		kb, _ := strconv.parse_u64(fields[0])
		return kb * 1024
	}
	return field(text, "VmRSS:"), field(text, "RssAnon:")
}
