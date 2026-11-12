// What the model asks of the interface: a toast, a notification. The model records it where its state changes (apply_event), and
// the build does it (effects_apply, on the interface's thread, right after the answers and events begin_build ran). The model then
// runs where there is no window (a test, a thread of its own) and never reaches a toast or the system's notifications itself.
package ocn

import "core:strings"
import "gt:ui"

Effect_Toast :: struct { kind: ui.Toast_Kind, text: string }

// A toast about a session: its title, then `what` and `detail`; a click on it opens the session (settings.odin toast_session).
Effect_Session_Toast :: struct { kind: ui.Toast_Kind, session, what, detail: string }

// A run ended in a session: told as the preferences say (settings.odin notify_finished).
Effect_Finished :: struct { session, outcome: string }

// A session waits for the user: a permission, a question (settings.odin notify_waiting).
Effect_Waiting :: struct { session, what, detail: string }

Effect :: union { Effect_Toast, Effect_Session_Toast, Effect_Finished, Effect_Waiting }   // (strings owned)

effect_toast :: proc(app: ^App, kind: ui.Toast_Kind, text: string) {
	append(&app.cx.effects, Effect_Toast{kind, strings.clone(text)})
}

effect_session_toast :: proc(app: ^App, kind: ui.Toast_Kind, session, what, detail: string) {
	append(&app.cx.effects, Effect_Session_Toast{kind, strings.clone(session), strings.clone(what), strings.clone(detail)})
}

effect_finished :: proc(app: ^App, session, outcome: string) {
	append(&app.cx.effects, Effect_Finished{strings.clone(session), strings.clone(outcome)})
}

effect_waiting :: proc(app: ^App, session, what, detail: string) {
	append(&app.cx.effects, Effect_Waiting{strings.clone(session), strings.clone(what), strings.clone(detail)})
}

// Does what was recorded, in order, then forgets it. On the interface's thread, while a build is open (the toasts are its state's).
effects_apply :: proc(app: ^App) {
	if len(app.cx.effects) == 0 { return }
	for e in app.cx.effects {
		switch x in e {
		case Effect_Toast:         ui.toast(x.kind, "%s", x.text)
		case Effect_Session_Toast: toast_session(app, x.kind, x.session, x.what, x.detail)
		case Effect_Finished:      notify_finished(app, x.session, x.outcome)
		case Effect_Waiting:       notify_waiting(app, x.session, x.what, x.detail)
		}
	}
	effects_clear(app)
}

// Forgets what was recorded without doing it (a test that only reads it).
effects_clear :: proc(app: ^App) {
	for e in app.cx.effects {
		switch x in e {
		case Effect_Toast:         delete(x.text)
		case Effect_Session_Toast: delete(x.session); delete(x.what); delete(x.detail)
		case Effect_Finished:      delete(x.session); delete(x.outcome)
		case Effect_Waiting:       delete(x.session); delete(x.what); delete(x.detail)
		}
	}
	clear(&app.cx.effects)
}
