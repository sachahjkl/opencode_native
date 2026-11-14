type: Changed

**The font settings use the toolkit's picker**: the interface, answers, code and terminal fonts are chosen in the font picker of every program of the toolkit, each family drawn in itself, the monospace ones first for code and the terminal. A family is loaded off the window's thread: choosing one no longer stalls the window. The "System" and "As the interface" choices are gone: pick the family by its name; a setting that still says "system" or "interface" draws in the client's own font.
