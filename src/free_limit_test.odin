package ocn

// The free-limit panel (src/md/features/free-limit.md): a step refused for the free limit, in any session, puts the
// panel in the composer's place until it resets; a paid provider, or the reset past, gives the composer back; another
// error does nothing.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import session "gt:testkit/session"
import "gt:testkit/unwatched"

@(test)
the_free_limit_takes_the_composers_place :: proc(t: ^testing.T) {
	unwatched.run(t, proc(t: ^testing.T) {
		context.allocator = runtime.heap_allocator()
		app, s := bench_app(t)
		defer { app.free_limit = {} }
		clear(&app.models)
		app.cx.catalog_version += 1
		session.frames(s, 2)
		testing.expect(t, session.find(s, "composer_well") != nil, "the composer")
		now := now_epoch_ms()
		failed :: proc(app: ^App, kind: string, created: f64, retry: string) {
			bench_event(app, fmt.tprintf(`{{"type":"session.step.failed","created":%f,"data":{{"sessionID":"other","error":{{"type":"%s","message":"x"%s}}}}}}`, created, kind, retry))
		}
		failed(app, "provider.rate-limit", now, "")
		session.frames(s, 2)
		testing.expect(t, session.find(s, "free_limit") == nil, "another error: nothing")
		failed(app, "provider.free-limit", now, `,"retryAfterMs":600000`)
		session.frames(s, 2)
		testing.expect(t, session.find(s, "free_limit") != nil, "the panel")
		testing.expect(t, session.find(s, "composer_well") == nil, "in the composer's place")
		testing.expect(t, abs(app.free_limit.reset_ms - (now + 600000)) < 1, "it resets when the server said")
		// a paid provider: the composer comes back
		append(&app.models, Model_Info{id = strings.clone("m"), provider = strings.clone("anthropic")})
		app.cx.catalog_version += 1
		session.frames(s, 2)
		testing.expect(t, session.find(s, "composer_well") != nil, "a paid provider: the composer")
		pop(&app.models)
		app.cx.catalog_version += 1
		session.frames(s, 2)
		testing.expect(t, session.find(s, "free_limit") != nil, "the panel again")
		// the reset past: the composer
		app.free_limit.reset_ms = now - 1
		session.frames(s, 2)
		testing.expect(t, session.find(s, "composer_well") != nil, "reset: the composer")
		// no time said: an hour
		app.free_limit = {}
		failed(app, "provider.free-limit", now, "")
		testing.expect(t, abs(app.free_limit.reset_ms - (now + FREE_LIMIT_FALLBACK_MS)) < 1, "an hour when none is said")
	})
}
