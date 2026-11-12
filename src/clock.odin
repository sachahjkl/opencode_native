package ocn

// The machine's offset from UTC, for the times shown on the local clock. Reading it is a system call (on Linux it may read the
// zone's file): it is read once as the program starts, before the window, then every minute by a thread of its own, so that a
// change of daylight saving time or of zone shows within a minute. The interface only reads the last value.

import "core:sync"
import "core:thread"
import "core:time"

CLOCK_WATCH_EVERY :: time.Minute

@(private = "file") offset_minutes: int   // (atomic: written by the watch, read by the interface)

local_offset_minutes :: proc() -> int { return sync.atomic_load(&offset_minutes) }

clock_watch_start :: proc() {
	sync.atomic_store(&offset_minutes, local_offset_read())
	thread.create_and_start(proc() {
		for {
			time.sleep(CLOCK_WATCH_EVERY)
			sync.atomic_store(&offset_minutes, local_offset_read())
		}
	}, self_cleanup = true)
}
