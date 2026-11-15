# Images

The images of a conversation (attached to prompts, handed back by tools), the projects' logos and the viewer show
textures of the toolkit's picture cache, `gt:pictures` (its intent: the toolkit's
`src/md/features/picture-cache.md`). `app.pictures` is the one cache of the program. This program decides only which
bytes an image is and how it is shown.

## Decisions

- **The key is `Image_Ref.key`.** A hash of the first and last 4 KiB of the image's text and of its length: a page
  read again gives the same key without reading megabytes. The cache adds the size class.
- **The server's text stays text.** An image arrives as base64 or as a data URL. `Image_Ref` keeps that text, not its
  bytes: most images of a long session are never shown, and decoding them all at read time costs the same work for
  nothing.
- **The bytes are made at a miss only.** `picture` asks the cache with no bytes first. Only when the cache does not hold
  that size does it decode the base64 and give the bytes, which the cache copies. A thumbnail shown for minutes decodes
  its base64 once.
- **Text that is no base64 goes to the cache as it is.** The cache then fails it as no picture file, and the thumbnail
  says so. No second failure path.
- **`frame` runs before the builds** (the main host's `before_input`): the views' windows are built inside the main
  frame, so one call a frame covers them.
- **The viewer asks for the whole picture** (`need_px` 0, mipmapped) at each build. It holds `Image_Ref`, never a
  `^Picture`: the cache's pointer is valid for one frame.
- **Copy is not the cache's.** Ctrl+C and Copy image decode the file again whole on the chores: the textures are
  scaled down and the GPU's pixels are not read back.

## Refused

- **ocn's own cache** (its eviction, its decode queue, its texture bookkeeping): a copy of `gt:pictures` with its own
  bugs.

## Open point

- The base64 of a miss is decoded on the interface's thread, in the frame that first shows that size (a few
  milliseconds for a screenshot of several MiB). `gt:pictures` has no way to run a transform of the bytes on its
  worker; when it has one, the base64 moves there.
