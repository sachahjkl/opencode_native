# Colours

opencode native draws in the colours of the theme the person chose, by role and by hue, as the toolkit's own widgets
do. Its own colours are one thing: the theme `OpenCode` (`THEME_OPENCODE` in `src/theme.odin`), a `ui.Theme_Def` like
the toolkit's themes. No other file holds a raw colour, except the session lamps (below).

## How a view asks for a colour

- `ui.theme_color(name)`: an entry of the toolkit's theme by its name, with no tag of the place where it is asked, as
  `ui.hue` does. It works while a view is built and in a custom draw. A view asks by role: `"text"`, `"soft text"`,
  `"weak text"`, `"faint text"`, `"bright text"`, `"background"`, `"bar background"`, `"card background"`,
  `"button background"`, `"border"`, `"well"`, `"bad text"`, the diff's entries.
- `ui.hue(.Accent)`, `ui.hue(.Green)`...: a colour by meaning (peach is the accent of `OpenCode`).
- `between(from, to, t)`: a shade `t` of the way from one entry to another, in sRGB steps (`ui.srgb_step`). A bar's
  gradient, a tinted plate. A shade between two steps of the theme keeps its place in every theme, dark or light;
  `ui.lighten` and `ui.darken` do not (a share toward white or black is a large step on a light page).
- `theme_colors()`: the `ui.Theme_Colors` of the version shown, for what is not drawn by the interface: the window's
  clear colour, the terminal's palette, the logo's tint, the background of a copied diagram. Before a theme is shown
  (a test, the first frame) it is `OpenCode` dark.

## The entries the program adds

The toolkit's palette has the five texts of every theme: `faint text`, `weak text`, `soft text` (weak 70 % of the way
to text, `ui.SOFT_STEP`: tool output, quiet labels), `text`, `bright text`. ocn registers in the toolkit's theme, from
the version shown (`theme_entries` in `src/style.odin`), only what the palette lacks:

- `link` (blue), `selection` (the accent, translucent), `selection text` (bright);
- the diff's entries: tints of green and red over the page, the line numbers between the line and the faint text.

They are added ahead of the palette's (ties go to the first). When the toolkit's palette gets them, the program's
entries go.

## Decisions

- **No recolouring.** Before, every view drew with opencode's hex constants and `theme_recolor` moved each to the theme
  shown (a grey to the same place on its greys, a colour to its nearest hue). It made ~90 constants a second theme
  beside the toolkit's, and one-off greys (`0xd8d8d8` for a name, `0xdadada` for a value) that no theme could name. Each
  one-off grey now takes the nearest role; a surface between two steps is a shade `between` them.
- **The palette is the toolkit's.** `ui.theme_palette` of the theme shown: its page is the theme's bg0, its text on
  the accent `ui.theme_on_accent`, its blue, purple, cyan and rose the theme's (before, they were 0: the toolkit fell
  back to the accent, and `ui.hue(.Blue)`, an Info intent, was peach).
- **The toolkit's surfaces.** What floats (menus, dialogs) and the ground of inline code take the toolkit's colours
  (bg3, the line): ocn's were a grey or two off.
- **The reading text is the theme's text.** The answers were `0xdcdcdc`, a step under the text; code `0xd4d4d4`. They
  take `text` and `soft text`: a shade of their own in every view is what made the second theme.
- **The texts are the toolkit's.** ocn registered faint, soft and bright text itself; the toolkit's palette now has them
  in every theme, the same values (soft: the same step from the same weak and text), so OpenCode looks the same.
  `ui.theme_color` replaces ocn's own reader of an entry (`themed`).
- **Raised cards are `ui.card` with their look.** A permission, a form, the person's prompt and a sub-agent's card give
  `ui.Card_Options` (a face from a top colour to a bottom one, an edge, a rim, a shadow: `warm_card`, `calm_card`).
  ocn's own `plate` drew the same in a custom draw; the toolkit's card also says the group to a screen reader and puts
  `CARD_PAD` on its four sides.
- **Session lamps stay raw.** `LAMP_*` are signals (works, at rest, waits), the same in every theme, drawn with
  `draw.hex`.
