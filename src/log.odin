// The log and the crash reports (gt:log, gt:crash): core:log's lines go to opencode-native.log in the state folder, written
// by the log's own thread (a write is a system call, which the interface's thread never makes); a crash writes a report with
// the log's last lines, and the next start says it.
package ocn

import "base:runtime"
import "gt:crash"
import tk_log "gt:log"
import "gt:ui"
import i18n "gt:i18n"

// The log, as context.logger, and the crash handler; `crashed`: the report of the last session when it did not end cleanly
// (owned, "" none). On the main thread, before the first build (they read and write the report folder).
log_start :: proc() -> (logger: runtime.Logger, crashed: string) {
	logger = tk_log.install({program = APP_SLUG, echo = true}, runtime.heap_allocator())
	crash.install({program = APP_SLUG, version = APP_VERSION, log_tail = {text = tk_log.tail, user = logger.data}})
	crashed, _ = crash.last_report(runtime.heap_allocator())
	crash.begin_session()
	return
}

// A clean exit: the next start says no crash.
log_stop :: proc(logger: runtime.Logger) {
	crash.end_session()
	tk_log.close(logger)
}

// The last session's report, said once in the window: a click opens it (nothing is sent anywhere).
crash_say :: proc(app: ^App, report: string) {
	if report == "" { return }
	app.cx.crash_report = report
	ui.announce(&app.announcer, .Warn, i18n.tr("opencode native stopped unexpectedly last time: click to open its report"), action = proc(user: rawptr) { ui.open((^App)(user).cx.crash_report) }, user = app)
}
