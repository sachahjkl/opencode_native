package occ

// A sampling profiler for the bench (-define:OCC_PROFILE=true, Windows, with -debug for the names): a thread that stops the
// bench's thread every millisecond and walks its stack (RtlVirtualUnwind), named by DbgHelp at the end. For each case: the
// functions the samples were in (self), and those on the stack (total). docs/performance.md says how to run it.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

OCC_PROFILE :: #config(OCC_PROFILE, false)

CONTEXT_WANTED :: 0x00100003   // CONTEXT_AMD64 | CONTROL | INTEGER
PROFILE_DEPTH :: 48
PROFILE_TOP   :: 26
PROFILE_CHAIN :: 5     // frames of a stack, from where the sample fell
PROFILE_CHAINS_TOP :: 24

@(private = "file")
Profile :: struct {
	target:  win.HANDLE,
	stop:    bool,
	sampler: ^thread.Thread,
	self:    map[uintptr]int,
	total:   map[uintptr]int,
	chains:  map[[PROFILE_CHAIN]uintptr]int,
	samples: int,
}

@(private = "file") profile: Profile

@(private = "file")
_uses :: proc() {   // (-vet: what only the sampler uses, when it is left out)
	_ = fmt.tprint
	none: []int
	slice.reverse(none)
	_ = sync.Mutex{}
	_ = time.Millisecond
	_ = strings.contains
}

when OCC_PROFILE {
	foreign import dbghelp "system:Dbghelp.lib"
	foreign import ntdll_lib "system:ntdll.lib"

	@(private = "file")
	Symbol_Info :: struct {
		size_of_struct, type_index: u32,
		reserved: [2]u64,
		index, size: u32,
		mod_base: u64,
		flags: u32,
		value, address: u64,
		register, scope, tag, name_len, max_name_len: u32,
		name: [256]u8,
	}

	@(default_calling_convention = "system", private = "file")
	foreign dbghelp {
		SymInitialize :: proc(process: win.HANDLE, path: cstring, invade: win.BOOL) -> win.BOOL ---
		SymFromAddr :: proc(process: win.HANDLE, addr: u64, displacement: ^u64, sym: ^Symbol_Info) -> win.BOOL ---
		SymSetOptions :: proc(options: u32) -> u32 ---
	}

	@(default_calling_convention = "system", private = "file")
	foreign ntdll_lib {
		RtlLookupFunctionEntry :: proc(pc: u64, base: ^u64, history: rawptr) -> rawptr ---
		RtlVirtualUnwind :: proc(kind: u32, base, pc: u64, entry: rawptr, ctx: ^win.CONTEXT, handler: ^rawptr, frame: ^u64, nonvolatile: rawptr) -> rawptr ---
	}

	@(private = "file")
	sample :: proc(p: ^Profile) {
		ctx: win.CONTEXT
		ctx.ContextFlags = CONTEXT_WANTED
		if win.SuspendThread(p.target) == max(u32) { return }
		if !win.GetThreadContext(p.target, &ctx) { win.ResumeThread(p.target); return }
		stack: [PROFILE_DEPTH]uintptr
		n := 0
		for n < PROFILE_DEPTH && ctx.Rip != 0 {
			stack[n] = uintptr(ctx.Rip)
			n += 1
			base: u64
			entry := RtlLookupFunctionEntry(ctx.Rip, &base, nil)
			if entry == nil { break }
			handler: rawptr
			frame: u64
			_ = RtlVirtualUnwind(0, base, ctx.Rip, entry, &ctx, &handler, &frame, nil)
		}
		// (nothing is allocated with the target stopped: it may hold the heap's lock)
		win.ResumeThread(p.target)
		if n == 0 { return }
		chain: [PROFILE_CHAIN]uintptr
		for k in 0 ..< min(n, PROFILE_CHAIN) { chain[k] = stack[k] }
		p.chains[chain] += 1
		p.samples += 1
		p.self[stack[0]] += 1
		for a, i in stack[:n] {
			seen := false
			for b in stack[:i] { if b == a { seen = true; break } }
			if !seen { p.total[a] += 1 }
		}
	}

	@(private = "file")
	name_of :: proc(addr: uintptr) -> string {
		sym: Symbol_Info
		sym.size_of_struct = 88
		sym.max_name_len = 255
		d: u64
		if SymFromAddr(win.GetCurrentProcess(), u64(addr), &d, &sym) { return fmt.tprintf("%s", string(sym.name[:sym.name_len])) }
		return fmt.tprintf("0x%x", addr)
	}

	@(private = "file")
	print_top :: proc(title: string, m: map[uintptr]int, samples: int) {
		by_name := make(map[string]int, allocator = context.temp_allocator)
		for a, n in m { by_name[name_of(a)] += n }
		Row :: struct { name: string, n: int }
		rows := make([dynamic]Row, context.temp_allocator)
		for k, n in by_name {
			skip := false
			for noise in ([]string{"thread::", "testing::", "Rtl", "BaseThread", "tk_session", "bench_frame", "a_long_conversation", "WaitForSingle", "NtWait", "occ::frame"}) {
				if strings.contains(k, noise) { skip = true }
			}
			if !skip { append(&rows, Row{k, n}) }
		}
		slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.n > b.n })
		fmt.printfln("  %s", title)
		for r in rows[:min(len(rows), PROFILE_TOP)] { fmt.printfln("    %5.1f %%  %s", 100 * f64(r.n) / f64(max(samples, 1)), r.name) }
	}
}

when OCC_PROFILE {
	@(private = "file")
	print_chains :: proc(p: ^Profile) {
		by := make(map[string]int, allocator = context.temp_allocator)
		for c, n in p.chains {
			b := strings.builder_make(context.temp_allocator)
			for a, i in c {
				if a == 0 { break }
				if i > 0 { strings.write_string(&b, " < ") }
				strings.write_string(&b, name_of(a))
			}
			by[strings.to_string(b)] += n
		}
		Row :: struct { name: string, n: int }
		rows := make([dynamic]Row, context.temp_allocator)
		for k, n in by { if !strings.has_prefix(k, "NtWait") { append(&rows, Row{k, n}) } }
		slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.n > b.n })
		fmt.println("  chains")
		for r in rows[:min(len(rows), PROFILE_CHAINS_TOP)] { fmt.printfln("    %5.1f %%  %s", 100 * f64(r.n) / f64(max(p.samples, 1)), r.name) }
	}
}

// Samples the calling thread until profile_end.
profile_begin :: proc() {
	when OCC_PROFILE {
		@(static) symbols: bool
		if !symbols { symbols = true; SymSetOptions(0x2); SymInitialize(win.GetCurrentProcess(), nil, true) }
		p := &profile
		win.DuplicateHandle(win.GetCurrentProcess(), win.GetCurrentThread(), win.GetCurrentProcess(), &p.target, 0, false, win.DUPLICATE_SAME_ACCESS)
		p.stop, p.samples = false, 0
		clear(&p.self)
		clear(&p.total)
		clear(&p.chains)
		reserve(&p.self, 1 << 16)
		reserve(&p.total, 1 << 16)
		p.sampler = thread.create_and_start_with_poly_data(p, proc(p: ^Profile) {
			for !sync.atomic_load(&p.stop) {
				sample(p)
				// (a wait of its own: precise_sleep's timer is the app's)
				start := time.tick_now()
				for time.tick_since(start) < time.Millisecond { win.SwitchToThread() }
			}
		})
	}
}

profile_end :: proc(name: string) {
	when OCC_PROFILE {
		p := &profile
		sync.atomic_store(&p.stop, true)
		thread.join(p.sampler)
		thread.destroy(p.sampler)
		win.CloseHandle(p.target)
		fmt.printfln("profile %s: %d samples", name, p.samples)
		print_top("self", p.self, p.samples)
		print_top("total", p.total, p.samples)
		print_chains(p)
	}
}
