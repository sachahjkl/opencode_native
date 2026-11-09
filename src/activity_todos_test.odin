package occ

import "base:runtime"
import "core:testing"

// A session's todo list is there at once when the session comes back: its pages read again, it came a moment late, the line over the
// composer appeared then and the whole conversation moved up by its height.
@(test)
a_session_s_todo_list_comes_back_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()   // (the App keeps what it made, as the program does, till it ends)
	app := new(App)
	defer free(app)
	LIST :: `{"todos":[{"content":"build","status":"completed"},{"content":"ship","status":"in_progress"}]}`
	show :: proc(app: ^App, id: string, list: string, loaded: bool) {
		chat_reset(&app.chat)
		app.chat.id, app.chat.loaded = id, loaded
		activity_reset(app)
		if list != "" {
			parts := make([dynamic]Part)
			append(&parts, Part{kind = .Tool, tool_name = "todowrite", input = list})
			append(&app.chat.messages, Message{id = "m1", kind = .Assistant, parts = parts})
		}
		todos_update(app)
	}
	show(app, "ses_a", LIST, true)
	testing.expect_value(t, len(app.activity.todos), 2)
	show(app, "ses_b", "", true)   // (its own pages have none, and none older: no list)
	testing.expect_value(t, len(app.activity.todos), 0)
	// back to the first: its messages not read yet, its list is there all the same
	show(app, "ses_a", "", false)
	testing.expect_value(t, len(app.activity.todos), 2)
	if len(app.activity.todos) == 2 { testing.expect_value(t, app.activity.todos[1].content, "ship") }
	todos_update(app)   // (another frame: still there)
	testing.expect_value(t, len(app.activity.todos), 2)
}
