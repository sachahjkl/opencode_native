package ocn

// The bytes of an image as the server gives it (its file, base64 text, a data URL), and one decoder for them (the
// toolkit's gt:image): a PNG and a WebP (built in: IMAGE_WEBP, from this program's own Rust library).

import "base:runtime"
import "core:encoding/base64"
import "core:slice"
import "core:strings"
import "core:testing"
import "gt:image"
import "gt:png"

@(test)
an_image_s_bytes_are_its_file :: proc(t: ^testing.T) {
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
		img, _, ok := image.decode(data, h)
		testing.expectf(t, ok && img.width == w && img.height == hh, "%d decoded: %dx%d", i, img.width, img.height)
		image.destroy(&img, h)
		b64, _ := base64.encode(data, allocator = context.temp_allocator)
		url := strings.concatenate({"data:image/png;base64,", b64}, context.temp_allocator)
		// (base64 split over lines, as a mail holds it)
		lines := strings.concatenate({b64[:10], "\r\n ", b64[10:]}, context.temp_allocator)
		for ref in ([]Image_Ref{image_ref(string(data), .Bytes, "", ""), image_ref(url, .Data_Url, "", ""), image_ref(lines, .Base64, "", "")}) {
			bytes, owned := image_bytes(ref, h)
			testing.expectf(t, slice.equal(bytes, data), "%d: the file, from %v", i, ref.encoding)
			testing.expect_value(t, owned, ref.encoding != .Bytes)
			if owned { delete(bytes, h) }
		}
	}
	// (no base64: the text itself, which the cache says is no picture file)
	bytes, owned := image_bytes(image_ref("data:image/png;base64,***", .Data_Url, "", ""), h)
	testing.expect(t, !owned && string(bytes) == "data:image/png;base64,***", "what is not base64 stays text")
}
