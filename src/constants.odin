// The numbers and colours of the interface's newer parts, in one place, by what they tune. (_EM: in font sizes, _PX: in logical
// pixels, _MS: in milliseconds, HEX_: sRGB.)
package occ


////////////////////////////////
// What waits in the inbox: the list over the composer (queue.odin)

QUEUE_ROWS_SHOWN   :: 5     // rows before the list scrolls: the composer stays where it is
QUEUE_ROW_H_EM     :: 1.7
QUEUE_HEAD_H_EM    :: 1.5
QUEUE_MARK_W_EM    :: 1.4   // its number
QUEUE_GLYPH_EM     :: 1.4   // an action, where words have no room
QUEUE_WORDS_MIN_EM :: 26    // the column this wide: the actions are words, the send button says what it does
QUEUE_LINE_CHARS   :: 200   // of a message, on its row (the row cuts the rest)
QUEUE_NAME_CHARS   :: 60    // ... for a screen reader
QUEUE_GONE_MAX     :: 64    // items remembered as gone (a late list must not bring them back)

////////////////////////////////
// The statistics panel (stats.odin)

CONTEXT_DEBOUNCE_MS :: 400    // a step ended: its context is read a little after, once
CTX_BYTES_PER_TOKEN :: 4      // the server gives text, not sizes: this is what a size is estimated from
CTX_IMAGE_TOKENS    :: 1200   // ... and an image, whose size says nothing of what it costs
CTX_BAR_PARTS       :: 6      // parts of the bar, the largest; the others are one
CTX_ITEMS_SHOWN     :: 12     // of a part, unfolded
CTX_OPEN_LINES      :: 40     // of an item, opened
CTX_ITEM_CHARS      :: 90     // of its name
CTX_SHADE_FIRST     :: 0.95   // the bar: the accent, fainter from part to part
CTX_SHADE_STEP      :: 0.14
CTX_SHADE_LAST      :: 0.2
STATS_WIDE_EM       :: 34     // the panel this wide: rankings have their columns
STATS_METER_EM      :: 22     // ... this wide, a smaller bar
STATS_METER_W_EM    :: 4
STATS_STACK_EM      :: 18     // ... under this, a value goes under its key, and a part of the context loses its share
STATS_KEY_SHARE     :: 0.38   // of the panel, at most: a key, beside its value
STATS_NARROW_PAD_EM :: 0.7
STATS_KEY_W_EM      :: 11
FIGURE_W_EM         :: 6.2    // a column of the figures: they line up when they wrap
FIGURE_H_EM         :: 2.1
FIGURE_CAPTION_EM   :: 1.2
FS_FIGURE           :: 1.7    // a figure, in font sizes

////////////////////////////////
// What runs in the background: the tray under the composer

ACT_POLL_MS        :: 1200    // while something runs and one looks at it
ACT_IDLE_POLL_MS   :: 5000    // while something runs and the tray is closed
ACT_TAIL_BYTES     :: 24576   // of a command's output, kept
ACT_OUTPUT_CHUNK   :: "65536" // read at a time (text of the query)
ACT_JOBS_MAX       :: 24      // commands kept, the finished ones go first
ACT_FINISHED_SHOWN :: 6       // sub-agents over, in the tray
ACT_COLUMNS_MIN_EM :: 44      // the column this wide: the todo list goes beside what runs
ACT_KEYS_MIN_EM    :: 40      // ... the keys are recalled
ACT_TODO_SHARE     :: 0.4
ACT_PEEK_LINES     :: 10      // of a sub-agent's work, kept
ACT_PEEK_MESSAGES  :: "6"     // read to find them (text of the query)
ACT_LINES_REST     :: 2       // lines of output on a row
ACT_LINES_SELECTED :: 6       // ... on the selected one
ACT_LINES_OPEN     :: 24      // ... on a command opened with Enter
ACT_MAX_H_FRACTION :: 0.42    // of the window: the most the tray takes
ACT_ANIM_RATE      :: 15      // about 200 ms to open: enough frames to be seen moving
ACT_FIRST_H_EM     :: 14      // its height before it was ever measured
ACT_LINE_CHARS     :: 220
TODO_MARK_H_EM :: 1.75   // an item's mark, centred on the first line of its text
TRAY_RADIUS :: 10
TRAY_PAD_EM :: 1.0   // what is in the tray, from its edges
HEX_ACT_ROW_SELECTED :: 0x151515ff
HEX_ACT_WELL         :: 0x0a0a0aff

////////////////////////////////
// The composer's history

HISTORY_MAX :: 400   // prompts kept in the file

////////////////////////////////
// The command palette

PALETTE_W_EM        :: 40
PALETTE_TOP         :: 0.13     // of the window
PALETTE_ROWS        :: 11
PALETTE_ROWS_MAX    :: 200      // built at most: past that, one types
PALETTE_SESSIONS    :: 6        // shown with an empty field
USAGE_HALF_LIFE_MS  :: 14 * 24 * 3600 * 1000.0
USAGE_SCORE         :: 40.0     // of one recent choice, in the fuzzy score's units
HEX_PAL_SELECTED    :: 0x0c0c0cff

////////////////////////////////
// Commands

ZOOM_FACTOR :: 1.1

////////////////////////////////
// Context menus

CTX_MENU_KEY :: "context_menu"

QUOTE_CHIP_W_EM :: 11

////////////////////////////////
// Attachments

ATTACH_THUMB_H_PX :: 84
ATTACH_THUMB_W_PX :: 160
ATTACH_MAX_BYTES  :: 20 * 1024 * 1024   // of one image

////////////////////////////////
// The home page

HOME_RECENT    :: 8
HOME_FOLDERS   :: 8
HOME_RUNNING   :: 6
HOME_TOP_EM    :: 3.2

////////////////////////////////
// Tool calls: diffs, lines of files

HEX_DIFF_ADD_BG     :: 0x12261aff
HEX_DIFF_DEL_BG     :: 0x2c1517ff
HEX_DIFF_ADD_MARK   :: 0x1f5c33ff   // what changed in a line
HEX_DIFF_DEL_MARK   :: 0x7a2b31ff
HEX_DIFF_ADD_TEXT   :: 0xcdeed6ff
HEX_DIFF_DEL_TEXT   :: 0xf2cdd0ff
HEX_DIFF_LINE_NO    :: 0x4a4a4aff
TOOL_TAB            :: "    "
TOOL_LINE_CHARS     :: 400    // of one line, shown
DIFF_FOLDED_LINES   :: 16     // of a diff shown with its call folded
GUTTER_EM           :: 2.7

////////////////////////////////
// The sidebar (sidebar.odin)

SIDEBAR_HOLD_MS  :: 3000   // the pointer still over the list this long: it is not about to click, the rows may move
SIDE_MODES_H_EM  :: 1.9    // the switch of the modes, in its own smaller size
SIDE_INBOX_ROW_EM :: 2.9   // a row that also says its project
SIDE_PROJECT_CHARS :: 40   // of that word

////////////////////////////////
// The dialogs of schedules and artifacts (schedules.odin)

SCHEDULES_W_EM         :: 42     // as wide as the form's one row needs
SCHEDULES_TOP          :: 0.2    // of the window: where it starts, it grows down
SCHEDULES_FIRST_H_EM   :: 3      // what it holds before it was ever measured
SCHEDULES_HEAD_EM      :: 4.2    // its title and its gaps, which the window keeps
SCHEDULES_ROW_H_EM     :: 2.8    // one that is planned
SCHEDULES_MODES_W_EM   :: 17     // In, Every, At, Cron
SCHEDULES_ONE_ROW_EM   :: 33     // the room for the modes, the value and Plan it side by side
SCHEDULES_WORDS_MIN_EM :: 30     // ... for Delete to say it in words
ARTIFACTS_LIST_SHARE   :: 0.36   // of the dialog, at most: the list
ARTIFACTS_WORDS_MIN_EM :: 26     // the right side this wide: its buttons have their words

////////////////////////////////
// The end of the conversation

CHAT_FOOT_EM     :: 2      // what it keeps under the last message, run or no run
WORKING_LINE_EM  :: 1.4    // ... of which the line of a run

////////////////////////////////
// The throbber

THROBBER_STEP_MS    :: 70     // a step of the board
THROBBER_SETTLE     :: 7      // steps a new word takes to fall in place
THROBBER_FLIP_STEPS :: 7      // once it stands, a letter flips this often
THROBBER_GLYPHS     :: "abcdefghijklmnopqrstuvwxyz-_/.:"
THROBBER_WAVE_RATE  :: 0.0075 // the wave of light: radians per ms
THROBBER_WAVE_PITCH :: 0.62   // ... from one letter to the next
THROBBER_LIGHT_MIN  :: 0.42   // a letter out of the wave
ORBIT_RATE          :: 0.0045
ORBIT_DOTS          :: 3

////////////////////////////////
// The Preview panel

DOCK_DEFAULT :: "dock1 x0.560([*conversation] [*preview])"
HEX_PREVIEW_BG :: 0x0d0d0dff
TAB_PAD_EM     :: 0.9    // a tab's word, from its ends
TAB_LINE_INSET_EM :: 0.6 // the line under the tab shown, from them
DOCK_TAB_H_EM  :: 2.1
TOOLTIP_DELAY_S :: 0.5   // over a button of the title bar
HEADER_FIGURES_MIN_EM :: 40   // a conversation narrower than this keeps its title, not its figures
PREVIEW_PLACE_MS :: 40   // the page follows a move at this pace at most

////////////////////////////////
// The agents' browser tools

BROWSER_NAME        :: "preview"   // ("browser" is Desktop's: the server hides the tools of its names under it)
BROWSER_TAB         :: "tab_00000000-0000-4000-8000-000000000001"   // the panel's one page
BROWSER_RETRY_S     :: 5     // between two attempts at the socket
BROWSER_READ_MS     :: 20    // what an answer may wait for the socket's thread
BROWSER_CALL_S      :: 30    // a call the page does not answer ends after this
BROWSER_PROTOCOL    :: "2025-06-18"
BROWSER_DIR_WAIT_MS :: 100   // while the folder of the session shown is not known
BROWSER_DIR_WAITS   :: 40    // ... that many times: then the server's default folder (the home page)
BROWSER_REOPEN_MS   :: 400

////////////////////////////////
// Updates (src/update: what is checked; updater.odin)

UPDATE_HOST       :: "https://github.com"
UPDATE_STABLE_DIR :: "/sachahjkl/opencode_native/releases/latest/download/"
UPDATE_BETA_DIR   :: "/sachahjkl/opencode_native/releases/download/channel-beta/"

////////////////////////////////
// The way back to the end of the conversation

GO_BOTTOM_SCREENS :: 1.2   // this far from the end, in screens
GO_BOTTOM_RATE    :: 20
GO_BOTTOM_W_EM    :: 6.5

////////////////////////////////
// Pacing, and the status bar's rate

// The dialogs one can resize: what they open at and the least they go to, in em (the window has the last word). (Schedules is as tall
// as what it holds, and no longer one of them: its place stays, layout.dialogs is read by position.)
Dialog :: enum u8 { Settings, Help, Changes, Files, Schedules, Artifacts }
DIALOG_PREFERRED_EM := [Dialog][2]f32{.Settings = {62, 44}, .Help = {42, 44}, .Changes = {62, 46}, .Files = {74, 48}, .Schedules = {54, 44}, .Artifacts = {70, 46}}
DIALOG_MIN_EM       := [Dialog][2]f32{.Settings = {40, 24}, .Help = {30, 20}, .Changes = {34, 20}, .Files = {44, 22}, .Schedules = {36, 22}, .Artifacts = {44, 22}}
DIALOGS_SAVED_WITH_STATS :: 7   // sizes in a layout.dialogs written when Statistics was a dialog, the second of them
LOGO_EDGE_CHROMA     :: 142    // red minus blue of the logo's edge in the file (0xe8935a)
TEXT_SMOOTH_SCALE    :: 1.5    // below this scale, text is smoothed per colour stripe when the system does (main.odin text_mode_follow)
OPEN_HOLD_MS         :: 200    // a conversation's first page may take this long before "Loading" is shown instead of what was there
PENDING_SHOW_MS      :: 500    // requests in flight are said in the status bar once they last: most end before anyone could read it
TERM_COLS            :: 80     // a shell before its panel is laid out
TERM_ROWS            :: 24
TERM_SCROLLBACK_LINES :: 10000
TERM_PAD             :: 6      // between the panel and the grid
TERM_KEY_BYTES       :: 128
TERM_WHEEL_LINES     :: 3      // what a notch scrolls
TERM_TAB_CHARS       :: 24
TERM_READ_MS         :: 5      // what a key may wait for its shell's thread
TERM_PANEL_BASE      :: 1000   // a shell's id in the dock is this and up: Panel's values stay under it
TERM_OUT_MAX         :: 1 << 20   // bytes waiting for a socket on its way: past that, what is typed is dropped
TERM_RETRIES         :: 8      // a lost socket is opened again this many times, then on a click or when the server answers again
TERM_RETRY_MS        :: 500    // before the first of them; each wait doubles
TERM_RETRY_MOST_MS   :: 8000   // ... up to this
TERM_RETRY_STEP_MS   :: 100    // how soon a wait hears it is over
TERM_STABLE_MS       :: 5000   // a socket that stayed this long counts as a success: the attempts start over
TERM_BANNER_H_EM     :: 2.4    // what says a shell ended
TERM_NEW_EM          :: 1.7    // the + of a strip, as high as the dock's own buttons
TERM_FAINT           :: 0.6
TERM_CURSOR_ALPHA    :: 0.6
HEX_TERM_BG          :: 0x0d0d0dff
HEX_TERM_SELECTION   :: 0x3a4a66ff
INTEGRATIONS_ROWS    :: 40     // shown at once: the rest is searched
CONNECT_POLL_MS      :: 1500   // how often a login under way is asked about
CONNECT_POLL_MISSES  :: 5      // readings of it that fail in a row before they stop and the dialog says so
MENTION_ROWS         :: 7      // what @ proposes at once
MENTION_DETAIL_CHARS :: 60
FILES_FOUND_MAX      :: 200    // of a search in the dialog
FILES_LIST_W_EM      :: 22
FILE_SNIFF_BYTES     :: 8192   // looked at for a zero byte: not text
FILE_VIEW_MAX_BYTES  :: 262144 // of a file, shown; the rest is said
CHANGES_OPEN_FILES :: 6     // the files of a list shown unfolded
CHANGES_DIFF_LINES :: 400   // of a file, before the rest is counted

SETTINGS_NAV_EM       :: 14   // the list of the pages
SETTINGS_NAV_ICONS_EM :: 4    // the same with its icons alone
SETTINGS_NARROW_EM    :: 40   // a dialog narrower than this has them alone

FORM_BODY_H_EM     :: 20     // the most what a form asks takes, then it scrolls
FORM_BODY_WINDOW   :: 0.45   // and of the height of the window
FORM_LINE_EM       :: 2.2    // a line of it (form_height: what it would take)
FORM_FIELD_GAP_EM  :: 0.95
FORM_OPTION_GAP_EM :: 0.25

NAV_HISTORY_MAX :: 100   // places remembered for Back and Forward
NAV_RESTORE_NEAR_PX    :: 1     // the view is on its message this near
NAV_RESTORE_STILL      :: 3     // frames it stays there before it is left alone
NAV_RESTORE_FRAMES_MAX :: 60    // however long the heights around it take to settle
NAV_RESTORE_WAIT_MS    :: 4000  // without a page or a placing for this long, the view is the reader's again
DEFERRED_MOST          :: 5     // a read asked again and again still comes after this many of its waits
WAITS_GONE_MAX         :: 128   // permissions and forms remembered as answered (a late list must not bring them back)

OS_SETTINGS_READ_MS :: 2000   // how often the system's animation setting is read
POINTER_MOVING_MS :: 80                         // since the last move or notch: the pointer is still moving
FPS_SMOOTH   :: 0.08           // the status bar's rate: how fast it follows
FPS_RESTED_S :: 0.05           // a longer gap between two frames: the loop rested
