package occtools

import "core:os"
import win32 "core:sys/windows"

// What a process holds, in bytes: in physical memory, and of its own.
memory_of :: proc(p: os.Process) -> (working, private: u64) {
	c: win32.PROCESS_MEMORY_COUNTERS_EX
	c.cb = size_of(c)
	if !win32.GetProcessMemoryInfo(win32.HANDLE(p.handle), cast(win32.PPROCESS_MEMORY_COUNTERS)&c, size_of(c)) { return 0, 0 }
	return u64(c.WorkingSetSize), u64(c.PrivateUsage)
}
