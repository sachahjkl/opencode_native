// A few threads that run work in the order it came, and work that waits for its time with no thread asleep for it: the workers
// wait on one condition, timed by the soonest work due. Each connection has one for its requests (conn.odin), the App one of a
// single thread for what the interface must not wait for (App_Context.chores: the keyring, the files that say where the server
// runs).
//
// A pool of no thread runs work at once on the thread that adds it, and timed work when pool_pump says: a test drives it so,
// in its own order and by its own clock.
package ocn

import "core:sync"
import "core:thread"
import "core:time"

Work_Proc :: #type proc(data: rawptr)

@(private = "file")
Work :: struct { fn: Work_Proc, data: rawptr, due_ms: i64 }

Work_Pool :: struct {
	lock:     sync.Mutex,
	changed:  sync.Cond,          // work came, the clock moved, the stop: the workers look again
	rested:   sync.Cond,          // a work ended, or a worker waits: pool_wait_rest looks again
	ready:    [dynamic]Work,      // oldest first
	timed:    [dynamic]Work,      // not due yet, in no order (a few: the soonest is looked for)
	threads:  [dynamic]^thread.Thread,
	size:     int,                // threads (0: work runs on the thread that adds it)
	running:  int,                // works taken and not ended
	waiting:  int,                // workers waiting for work
	stopping: bool,
	joined:   int,                // threads pool_stop joined
	looks:    int,                // times a worker looked at what is due (a test sees that it looked)
	clock:    ^i64,               // (atomic) a test's clock in ms; nil: the monotonic clock. Workers then wait for pool_poke, not for a time
	origin:   time.Tick,
}

Pool_State :: struct { ready, timed, running, waiting, threads, looks: int }

// `size` threads, started now.
pool_init :: proc(p: ^Work_Pool, size: int, clock: ^i64 = nil) {
	p.size, p.clock, p.origin = size, clock, time.tick_now()
	for _ in 0 ..< size { append(&p.threads, thread.create_and_start_with_poly_data(p, pool_worker)) }
}

// Work for a worker, `after_ms` from now (0: as soon as one is free).
pool_add :: proc(p: ^Work_Pool, fn: Work_Proc, data: rawptr, after_ms := 0) {
	if p.size == 0 && after_ms <= 0 { fn(data); return }
	sync.lock(&p.lock)
	if after_ms > 0 {
		append(&p.timed, Work{fn, data, pool_now(p) + i64(after_ms)})
		sync.cond_broadcast(&p.changed)   // (the soonest may be this one: every waiting worker computes its wait again)
	} else {
		append(&p.ready, Work{fn, data, 0})
		sync.cond_signal(&p.changed)
	}
	sync.unlock(&p.lock)
}

// The clock moved (a test's): the workers look at what is due.
pool_poke :: proc(p: ^Work_Pool) {
	sync.lock(&p.lock)
	sync.cond_broadcast(&p.changed)
	sync.unlock(&p.lock)
}

// On the calling thread: the work due, and what was ready. How many ran.
pool_pump :: proc(p: ^Work_Pool, all_timed := false) -> (ran: int) {
	for {
		sync.lock(&p.lock)
		pool_due(p, all_timed)
		if len(p.ready) == 0 { sync.unlock(&p.lock); return }
		w := p.ready[0]
		ordered_remove(&p.ready, 0)
		sync.unlock(&p.lock)
		w.fn(w.data)
		ran += 1
	}
}

// Every worker ends once what is ready and what waits for its time has run (the time is not waited for: at a stop it is due), then is joined.
pool_stop :: proc(p: ^Work_Pool) -> (joined: int) {
	sync.lock(&p.lock)
	p.stopping = true
	sync.cond_broadcast(&p.changed)
	sync.unlock(&p.lock)
	for t in p.threads {
		thread.join(t)
		thread.destroy(t)
		joined += 1
	}
	if p.size == 0 { pool_pump(p, all_timed = true) }
	p.joined += joined
	delete(p.threads); delete(p.ready); delete(p.timed)
	p.threads, p.ready, p.timed = nil, nil, nil
	return
}

pool_state :: proc(p: ^Work_Pool) -> Pool_State {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	return {len(p.ready), len(p.timed), p.running, p.waiting, len(p.threads), p.looks}
}

// Until nothing is ready or running and every worker waits (what is timed waits on), or `bound` passed: whether it rested. (Tests.)
pool_wait_rest :: proc(p: ^Work_Pool, bound: time.Duration) -> bool {
	start := time.tick_now()
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	for !(len(p.ready) == 0 && p.running == 0 && p.waiting == len(p.threads)) {
		left := bound - time.tick_since(start)
		if left <= 0 { return false }
		_ = sync.cond_wait_with_timeout(&p.rested, &p.lock, left)
	}
	return true
}

@(private = "file")
pool_now :: proc(p: ^Work_Pool) -> i64 {
	if p.clock != nil { return sync.atomic_load(p.clock) }
	return i64(time.duration_milliseconds(time.tick_since(p.origin)))
}

// (Under the lock.) What is due goes to the ready ones, in the order of its time; the soonest that is not (-1: none).
@(private = "file")
pool_due :: proc(p: ^Work_Pool, all: bool) -> (soonest: i64) {
	now := pool_now(p)
	soonest = -1
	for {
		at := -1
		for w, i in p.timed {
			if all || p.stopping || w.due_ms <= now {
				if at < 0 || w.due_ms < p.timed[at].due_ms { at = i }
			}
		}
		if at < 0 { break }
		append(&p.ready, p.timed[at])
		unordered_remove(&p.timed, at)
	}
	for w in p.timed { if soonest < 0 || w.due_ms < soonest { soonest = w.due_ms } }
	return
}

@(private = "file")
pool_worker :: proc(p: ^Work_Pool) {
	sync.lock(&p.lock)
	for {
		soonest := pool_due(p, false)
		p.looks += 1
		sync.cond_broadcast(&p.rested)
		if len(p.ready) > 0 {
			w := p.ready[0]
			ordered_remove(&p.ready, 0)
			p.running += 1
			sync.unlock(&p.lock)
			w.fn(w.data)
			free_all(context.temp_allocator)
			sync.lock(&p.lock)
			p.running -= 1
			sync.cond_broadcast(&p.rested)
			continue
		}
		if p.stopping { break }
		p.waiting += 1
		sync.cond_broadcast(&p.rested)
		if soonest < 0 || p.clock != nil {
			sync.cond_wait(&p.changed, &p.lock)
		} else {
			_ = sync.cond_wait_with_timeout(&p.changed, &p.lock, time.Duration(soonest - pool_now(p)) * time.Millisecond)
		}
		p.waiting -= 1
	}
	sync.unlock(&p.lock)
}
