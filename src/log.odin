// The log (stderr): a line is written by the App's chores, in the order said. A write is a system call, which the interface's
// thread never makes, and a terminal that reads stderr slowly would hold it.
package ocn

import "base:runtime"
import "core:fmt"

@(private = "file")
Log_Line :: struct { text: string }

log_line :: proc(app: ^App, format: string, args: ..any) {
	line := new(Log_Line, runtime.heap_allocator())
	line.text = fmt.aprintf(format, ..args, allocator = runtime.heap_allocator())
	pool_add(&app.cx.chores, proc(data: rawptr) {
		line := (^Log_Line)(data)
		fmt.eprintln(line.text)
		delete(line.text, runtime.heap_allocator())
		free(line, runtime.heap_allocator())
	}, line)
}
