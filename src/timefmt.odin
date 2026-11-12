package ocn

// Every time the program shows, in one place: the toolkit's timefmt formats them; this file adds the local clock's offset
// (clock.odin reads it off the interface thread), the 24-hour preference, the server's epoch milliseconds, and the few
// forms that are this program's own (a tool call's tenths, a limit's time left, a server's timings).

import "core:fmt"
import "core:math"
import "core:time"
import "gt:timefmt"

MS_PER_S         :: timefmt.MS_PER_S
NS_PER_MS        :: 1e6
SECS_PER_MINUTE  :: timefmt.SECS_PER_MINUTE
SECS_PER_HOUR    :: timefmt.SECS_PER_HOUR
SECS_PER_DAY     :: timefmt.SECS_PER_DAY
MINUTES_PER_HOUR :: timefmt.MINUTES_PER_HOUR
MINUTES_PER_DAY  :: timefmt.MINUTES_PER_DAY

// Now, as the server counts time: milliseconds since 1970.
now_epoch_ms :: proc() -> f64 { return f64(time.time_to_unix_nano(time.now())) / NS_PER_MS }

// How long ago `t` was (epoch ms), seen at `now`: "now", "3m", "2h", "5d", "1w". "": not known.
age_text :: proc(now, t: f64) -> string {
	if t <= 0 { return "" }
	return timefmt.age(now - t)
}

// The local time of `t` (epoch ms): "14:32", "2:32 pm" (`clock24`: the preference); `seconds`: "14:32:05". "": not known.
clock_text :: proc(t: f64, clock24: bool, seconds := false) -> string {
	if t <= 0 { return "" }
	return timefmt.clock(t, local_offset_minutes(), {hours12 = !clock24, seconds = seconds})
}

// The local date of `t` (epoch ms): "Nov 10".
date_text :: proc(t: f64) -> string { return timefmt.date(t, local_offset_minutes()) }

// Whether two times (epoch ms) are on the same day of the local clock.
same_local_day :: proc(a, b: f64) -> bool {
	off := local_offset_minutes()
	return timefmt.local_day(a, off) == timefmt.local_day(b, off)
}

// The time of `t` to the second, with its date when it is not on the day of `now`: "14:32:05", "Nov 10, 14:32:05".
moment_text :: proc(t, now: f64, clock24: bool) -> string {
	clock := clock_text(t, clock24, seconds = true)
	if same_local_day(t, now) { return clock }
	return fmt.tprintf("%s, %s", date_text(t), clock)
}

// "4m 12s", "1h 03m": the time from `a` to `b` (epoch ms). "": `a` not known, or `b` not after it.
duration_text :: proc(a, b: f64) -> string {
	if a <= 0 || b <= a { return "" }
	return timefmt.duration(b - a)   // (in days from timefmt.DAYS_AFTER_HOURS on)
}

// The time from `a` to `b` (epoch ms) with its tenths under TOOL_ELAPSED_TENTHS_S, where two runs differ by them: "0.4s",
// "12s", "4m 12s"; under a tenth "<0.1s" ("0.0s" says nothing). `b` a little before `a` (the server's clock ahead of this
// one) is 0. "": `a` not known.
elapsed_text :: proc(a, b: f64) -> string {
	if a <= 0 { return "" }
	ms := max(b - a, 0)
	if ms < MS_PER_S / 10 { return "<0.1s" }
	if ms < TOOL_ELAPSED_TENTHS_S * MS_PER_S { return fmt.tprintf("%.1fs", ms / MS_PER_S) }
	return duration_text(a, b)
}

// A time the server measured: "350 ms", "1.2 s".
ms_text :: proc(ms: f64) -> string {
	if ms < MS_PER_S { return fmt.tprintf("%.0f ms", ms) }
	return fmt.tprintf("%.1f s", ms / MS_PER_S)
}

// The time left until `t` (epoch ms) from `now`, in whole minutes rounded up: "42 min", "1h 05", "3d 00h".
left_text :: proc(t, now: f64) -> string {
	mins := int(math.ceil((t - now) / (SECS_PER_MINUTE * MS_PER_S)))
	switch {
	case mins < MINUTES_PER_HOUR: return fmt.tprintf("%d min", mins)
	case mins < MINUTES_PER_DAY:  return fmt.tprintf("%dh %02d", mins / MINUTES_PER_HOUR, mins % MINUTES_PER_HOUR)
	}
	return fmt.tprintf("%dd %02dh", mins / MINUTES_PER_DAY, (mins % MINUTES_PER_DAY) / MINUTES_PER_HOUR)
}

// How long a tool call took ("0.4s", "12s", "4m 12s"), or has taken so far while it runs (`now`, epoch ms). "": its times
// are not known.
tool_elapsed :: proc(p: ^Part, running: bool, now: f64) -> string {
	end := running ? now : p.ended_ms
	if end <= 0 { return "" }
	return elapsed_text(p.started_ms, end)
}

// When a tool call ran, on the local clock to the second: "Started 14:32:05, ended 14:32:17", a day other than today's with
// its date ("Started Nov 10, 14:32:05"); while it runs, "running".
tool_when :: proc(p: ^Part, running: bool, now: f64, clock24: bool) -> string {
	start := fmt.tprintf("Started %s", moment_text(p.started_ms, now, clock24))
	if running { return fmt.tprintf("%s, running", start) }
	if p.ended_ms <= 0 { return start }
	return fmt.tprintf("%s, ended %s", start, moment_text(p.ended_ms, now, clock24))
}

// What the line over a goal's reason says of the time its limit resets: "resets at 12:20 · in 42 min", another day with its
// date ("resets on Nov 13 at 12:20 · in 3d 00h"); once past, "limit reset at 12:20".
reset_text :: proc(resets_ms, now_ms: f64, clock24: bool) -> string {
	if resets_ms <= now_ms { return fmt.tprintf("  ·  limit reset at %s", clock_text(resets_ms, clock24)) }
	left := left_text(resets_ms, now_ms)
	if !same_local_day(resets_ms, now_ms) {
		return fmt.tprintf("  ·  resets on %s at %s  ·  in %s", date_text(resets_ms), clock_text(resets_ms, clock24), left)
	}
	return fmt.tprintf("  ·  resets at %s  ·  in %s", clock_text(resets_ms, clock24), left)
}
