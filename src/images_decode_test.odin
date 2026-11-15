package ocn

// One image decoder (the toolkit's gt:image): a PNG and a WebP (built in: IMAGE_WEBP, from this program's own Rust
// library), as bytes, as base64 and as a data URL, fitted inside the size asked, their proportions kept.

import "base:runtime"
import "core:encoding/base64"
import "core:strings"
import "core:testing"
import "gt:image"
import "gt:png"

@(test)
pictures_are_decoded_by_the_toolkit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	h := runtime.heap_allocator()
	w, hh := 40, 20
	px := make([]u8, w * hh * 4, context.temp_allocator)
	for i in 0 ..< w * hh { px[i * 4], px[i * 4 + 3] = 200, 255 }
	png_data := png.encode(px, w, hh, allocator = context.temp_allocator)
	testing.expect(t, image.webp_available(), "WebP is built in")
	webp_data := image.webp_encode({pixels = px, width = w, height = hh}, lossless = true, allocator = context.temp_allocator)
	if !testing.expect(t, len(webp_data) > 0, "a WebP to read") { return }
	for data, i in ([][]u8{png_data, webp_data}) {
		img, why := image_decode_data(string(data), .Bytes, 0)
		testing.expectf(t, why == "" && img.width == w && img.height == hh, "%d as it is: %v %dx%d", i, why, img.width, img.height)
		image.destroy(&img, h)
		fitted, why2 := image_decode_data(string(data), .Bytes, 10)
		testing.expectf(t, why2 == "" && fitted.width == 10 && fitted.height == 5, "%d fitted, proportions kept: %dx%d", i, fitted.width, fitted.height)
		image.destroy(&fitted, h)
		b64, _ := base64.encode(data, allocator = context.temp_allocator)
		url := strings.concatenate({"data:image/png;base64,", b64}, context.temp_allocator)
		from_url, why3 := image_decode_data(url, .Data_Url, 0)
		testing.expectf(t, why3 == "" && from_url.width == w, "%d from a data URL: %v", i, why3)
		image.destroy(&from_url, h)
	}
	_, why := image_decode_data("not a picture", .Bytes, 0)
	testing.expect(t, why != "", "what is not a picture says so")
}
