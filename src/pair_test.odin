package occ

import "core:testing"

// The QR code takes the first address another device can reach (a tunnel, a network address), never this machine's: the TUI's
// first address was 127.0.0.1, of no use to a phone. Each link redeems the code at its address.
@(test)
the_pairing_code_goes_where_a_phone_can_reach :: proc(t: ^testing.T) {
	urls := []string{"http://127.0.0.1:49374", "https://54afcd7c7703596d.cfmfdgcrti5w.opentunnel.xyz", "http://192.168.1.20:49374"}
	testing.expect_value(t, pair_reachable(urls), "https://54afcd7c7703596d.cfmfdgcrti5w.opentunnel.xyz")
	testing.expect_value(t, pair_reachable({"http://127.0.0.1:4096", "http://localhost:4096", "http://[::1]:4096"}), "")
	testing.expect_value(t, pair_reachable({}), "")
	testing.expect_value(t, pair_link("https://a.example/", "abc123"), "https://a.example/auth/connect/abc123")
	testing.expect_value(t, pair_link("http://127.0.0.1:49374", "abc123"), "http://127.0.0.1:49374/auth/connect/abc123")
}
