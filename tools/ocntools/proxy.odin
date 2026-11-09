package ocntools

// Between the program and the server: what a real network does to it, at once and on demand. mute is a link gone silent with
// its sockets open, drop one that went away.

import "core:net"
import "core:sync"
import "core:thread"

PROXY_CHUNK :: 32 * 1024

Proxy :: struct {
	listener: net.TCP_Socket,
	target:   net.Endpoint,
	port:     int,
	opened:   int,   // connections so far (atomic)
	lock:     sync.Mutex,
	pairs:    [dynamic]^Pair,
}

@(private = "file")
Pair :: struct {
	a, b: net.TCP_Socket,
	mute: bool,   // (atomic)
	left: int,    // relays still running (atomic): the last closes the sockets
}

@(private = "file")
Relay :: struct {
	p:        ^Proxy,
	pair:     ^Pair,
	from, to: net.TCP_Socket,
}

proxy_start :: proc(target: net.Endpoint) -> (p: ^Proxy, ok: bool) {
	listener, err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if err != nil { return nil, false }
	at, bound := net.bound_endpoint(listener)
	if bound != nil { net.close(listener); return nil, false }
	p = new(Proxy)
	p.listener, p.target, p.port = listener, target, at.port
	thread.create_and_start_with_poly_data(p, proxy_accept, self_cleanup = true)
	return p, true
}

@(private = "file")
proxy_accept :: proc(p: ^Proxy) {
	for {
		client, _, err := net.accept_tcp(p.listener)
		if err != nil { return }
		server, dial_err := net.dial_tcp_from_endpoint(p.target)
		if dial_err != nil { net.close(client); continue }
		pair := new(Pair)
		pair.a, pair.b, pair.left = client, server, 2
		sync.lock(&p.lock)
		append(&p.pairs, pair)
		sync.unlock(&p.lock)
		sync.atomic_add(&p.opened, 1)
		for way in ([2][2]net.TCP_Socket{{client, server}, {server, client}}) {
			r := new(Relay)
			r^ = {p, pair, way[0], way[1]}
			thread.create_and_start_with_poly_data(r, relay_run, self_cleanup = true)
		}
	}
}

@(private = "file")
relay_run :: proc(r: ^Relay) {
	defer free(r)
	buf := make([]byte, PROXY_CHUNK)
	defer delete(buf)
	for {
		n, err := net.recv_tcp(r.from, buf)
		if err != nil || n == 0 { break }
		if sync.atomic_load(&r.pair.mute) { continue }
		if _, e := net.send_tcp(r.to, buf[:n]); e != nil { break }
	}
	_ = net.shutdown(r.pair.a, .Both)
	_ = net.shutdown(r.pair.b, .Both)
	if sync.atomic_sub(&r.pair.left, 1) != 1 { return }
	sync.lock(&r.p.lock)
	for q, i in r.p.pairs {
		if q == r.pair { unordered_remove(&r.p.pairs, i); break }
	}
	sync.unlock(&r.p.lock)
	net.close(r.pair.a)
	net.close(r.pair.b)
	free(r.pair)
}

proxy_opened :: proc(p: ^Proxy) -> int { return sync.atomic_load(&p.opened) }

// Nothing goes through any more; the sockets stay open.
proxy_mute :: proc(p: ^Proxy) {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	for q in p.pairs { sync.atomic_store(&q.mute, true) }
}

// Every connection ends now.
proxy_drop :: proc(p: ^Proxy) {
	sync.lock(&p.lock)
	defer sync.unlock(&p.lock)
	for q in p.pairs {
		_ = net.shutdown(q.a, .Both)
		_ = net.shutdown(q.b, .Both)
	}
}
