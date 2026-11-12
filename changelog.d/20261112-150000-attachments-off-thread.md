type: Fixed

**Attaching a large file and sending it no longer freezes the window**: a file attached, dropped or pasted is read and encoded on a thread of its own (Send waits for it, "reading the attachment…"), and a prompt's body, its images quoted, is made on the thread that sends it. The palette and the pickers fold what is typed and their items once, not at every frame.
