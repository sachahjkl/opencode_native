// The numbers and colours of the interface's newer parts, in one place, by what they tune. (_EM: in font sizes, _PX: in logical
// pixels, _MS: in milliseconds, HEX_: sRGB.)
package occ


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
BROWSER_POLL_MS     :: 10    // a read that found nothing, before the next
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

// The dialogs one can resize: what they open at and the least they go to, in em (the window has the last word).
Dialog :: enum u8 { Settings, Stats, Help, Changes, Files, Schedules, Artifacts }
DIALOG_PREFERRED_EM := [Dialog][2]f32{.Settings = {62, 44}, .Stats = {54, 46}, .Help = {42, 44}, .Changes = {62, 46}, .Files = {74, 48}, .Schedules = {54, 44}, .Artifacts = {70, 46}}
DIALOG_MIN_EM       := [Dialog][2]f32{.Settings = {40, 24}, .Stats = {34, 22}, .Help = {30, 20}, .Changes = {34, 20}, .Files = {44, 22}, .Schedules = {36, 22}, .Artifacts = {44, 22}}
INTEGRATIONS_ROWS    :: 40     // shown at once: the rest is searched
CONNECT_POLL_MS      :: 1500   // how often a login under way is asked about
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

OS_SETTINGS_READ_MS :: 2000   // how often the system's animation setting is read
POINTER_MOVING_MS :: 80                         // since the last move or notch: the pointer is still moving
FPS_SMOOTH   :: 0.08           // the status bar's rate: how fast it follows
FPS_RESTED_S :: 0.05           // a longer gap between two frames: the loop rested
