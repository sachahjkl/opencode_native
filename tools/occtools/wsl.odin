package occtools

// The Linux program from Windows, through WSL (occtools shots --linux, --linux-build), and what it needs, as commands of this tool:
//   wsl_build [folder]          (in Linux) this tree copied to a Linux folder and built there: the Rust and Odin outputs of Linux
//                               are not to mix with Windows' in build/. The last line said is the program. Default
//                               ~/.cache/opencode-native-build.
//   wsl_client <relay> <program> [arguments]
//                               (in Linux) the program on the opencode server of Windows, with an empty settings folder: a relay
//                               (socat, then `<relay> relay`, this tool built for Windows) brings that server's port into WSL.
//                               OC_PORT and OC_PASSWORD come by the environment, so that no command line shows the password.
//   relay <host> <port>         a TCP connection on stdin and stdout (Windows' own 127.0.0.1, for a program in WSL)
// shots.odin starts the first two with `wsl.exe`, in the flake's shell (nix develop): socat and the libraries the program opens.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"

WSL_BUILD_DEFAULT :: ".cache/opencode-native-build"

run_wsl_build :: proc(args: []string) -> int {
	when ODIN_OS == .Windows {
		fmt.eprintln("wsl_build: in Linux (shots --linux-build starts it through wsl.exe)")
		return 1
	} else {
		dest := len(args) > 0 ? args[0] : fmt.tprintf("%s/%s", os.get_env("HOME", context.temp_allocator), WSL_BUILD_DEFAULT)
		if !make_folder(dest) { return 1 }
		here, _ := os.get_working_directory(context.temp_allocator)
		if !run("rsync", "-a", "--delete", "--exclude", "build", "--exclude", "target", "--exclude", ".git", "--exclude", ".claude",
			"--exclude", "*.exe", "--exclude", "*.pdb", fmt.tprintf("%s/", here), fmt.tprintf("%s/", dest)) { return 1 }
		if !run_in({dir = dest}, "odin", "run", "tools/occtools", fmt.tprintf("-collection:gt=%s/src", GT_DEFAULT), "-out:build/occtools", "--", "build") { return 1 }
		fmt.printfln("%s/build/opencode-native", dest)
		return 0
	}
}

run_wsl_client :: proc(args: []string) -> int {
	when ODIN_OS == .Windows {
		fmt.eprintln("wsl_client: in Linux (shots --linux starts it through wsl.exe)")
		return 1
	} else {
		if len(args) < 2 { fmt.eprintln("wsl_client <relay> <program> [arguments]"); return EXIT_USAGE }
		relay, program := args[0], args[1]
		port := os.get_env("OC_PORT", context.temp_allocator)
		password := os.get_env("OC_PASSWORD", context.temp_allocator)
		settings, err := os.make_directory_temp("", "occ-wsl-*", context.temp_allocator)
		if err != nil { fmt.eprintln("wsl_client: no settings folder"); return 1 }
		defer os.remove_all(settings)

		env := make([dynamic]string, context.temp_allocator)
		append(&env, fmt.tprintf("XDG_CONFIG_HOME=%s", settings), "OPENCODE_NATIVE_NO_SETUP=1", fmt.tprintf("XDG_STATE_HOME=%s/state", settings))
		// the GPU through WSL, else the software driver; /usr/lib/wsl/lib is what the first one talks to
		if icd := os.get_env("MESA_ICD_DIR", context.temp_allocator); icd != "" {
			append(&env, fmt.tprintf("LD_LIBRARY_PATH=/usr/lib/wsl/lib:%s", os.get_env("LD_LIBRARY_PATH", context.temp_allocator)))
			append(&env, fmt.tprintf("VK_ICD_FILENAMES=%s/dzn_icd.x86_64.json:%s/lvp_icd.x86_64.json", icd, icd))
		}
		// What the opencode service writes where it runs: the client finds "This computer" by itself, and no command line holds the password.
		state := fmt.tprintf("%s/state/opencode", settings)
		if !make_folder(state) { return 1 }
		service := fmt.tprintf(`{{"url":"http://127.0.0.1:%s","password":%s}}`+"\n", port, json_string(password))
		if os.write_entire_file(fmt.tprintf("%s/service.json", state), service) != nil { return 1 }

		// (the relay runs on the Windows side, where 127.0.0.1 is the server)
		listen := fmt.tprintf("TCP-LISTEN:%s,bind=127.0.0.1,fork,reuseaddr", port)
		relay_p, rerr := os.process_start({command = {"socat", listen, fmt.tprintf("EXEC:%s relay 127.0.0.1 %s", relay, port)}, stdout = os.stdout, stderr = os.stderr})
		if rerr != nil { fmt.eprintln("wsl_client: socat does not start"); return 1 }
		defer { _ = os.process_kill(relay_p); _, _ = os.process_wait(relay_p) }

		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, program)
		append(&cmd, ..args[2:])
		return run_in({env = env_with({"XDG_CONFIG_HOME", "XDG_STATE_HOME", "LD_LIBRARY_PATH", "VK_ICD_FILENAMES"}, ..env[:])}, ..cmd[:]) ? 0 : 1
	}
}

// A JSON string of `s`.
@(private = "file")
json_string :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"', '\\': strings.write_byte(&b, '\\'); strings.write_byte(&b, c)
		case:           strings.write_byte(&b, c)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

run_relay :: proc(args: []string) -> int {
	if len(args) != 2 { fmt.eprintln("relay <host> <port>"); return EXIT_USAGE }
	port, ok := strconv.parse_int(args[1])
	if !ok { fmt.eprintln("relay: the port is a number"); return EXIT_USAGE }
	addr, aok := net.parse_ip4_address(args[0])
	if !aok { fmt.eprintln("relay: the host is an IPv4 address"); return EXIT_USAGE }
	socket, err := net.dial_tcp(net.Endpoint{addr, port})
	if err != nil { return 1 }
	// stdin to the socket on a thread of its own; the socket to stdout here, until the server closes
	t := thread.create_and_start_with_poly_data(socket, proc(socket: net.TCP_Socket) {
		buf: [16 * 1024]u8
		for {
			n, rerr := os.read(os.stdin, buf[:])
			if rerr != nil || n <= 0 { break }
			if _, serr := net.send_tcp(socket, buf[:n]); serr != nil { break }
		}
		net.shutdown(socket, .Send)
	})
	_ = t
	buf: [16 * 1024]u8
	for {
		n, rerr := net.recv_tcp(socket, buf[:])
		if rerr != nil || n <= 0 { break }
		if _, werr := os.write(os.stdout, buf[:n]); werr != nil { break }
	}
	net.close(socket)
	return 0
}
