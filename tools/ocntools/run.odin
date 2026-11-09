package ocntools

import "core:fmt"
import "core:os"
import toolbox "gt:toolbox"

// A command, said first ("> command"), its output going where ours goes. Did it succeed? (The toolkit's toolbox.run, with this
// tool's habit of showing what it runs.)
run :: proc(cmd: ..string) -> bool { return toolbox.run(cmd, {echo = true}) }

// A folder, with its parents. (make_directory_all says .Exist for one that is there, on Linux: that one is what was asked for.)
make_folder :: proc(path: string) -> bool {
	err := os.make_directory_all(path)
	if err == nil || os.is_directory(path) { return true }
	fmt.eprintfln("cannot make the folder %s: %v", path, err)
	return false
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}
