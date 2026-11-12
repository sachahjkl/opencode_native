type: Fixed

**Pasting files or an image no longer waits for the clipboard either**: a paste in the composer asks the clipboard for its files, its image and its text at once and takes them when they come; an image is decoded on a thread of its own. A slow program holding the clipboard, or a large picture, no longer freezes the window.
