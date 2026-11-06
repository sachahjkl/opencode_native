// No web view on Linux yet: links go to the system's browser (preview.odin asks web_available first).
package occ

Web_Act :: enum i32 { Back, Forward, Reload, Stop, Focus }

web_available :: proc() -> bool { return false }
web_start :: proc(app: ^App) {}
web_close :: proc(app: ^App) {}
web_navigate :: proc(app: ^App, url: string) {}
web_act :: proc(app: ^App, what: Web_Act) {}
web_can :: proc(what: Web_Act) -> bool { return false }
web_script :: proc(code: string, id: u64) {}
web_capture :: proc(id: u64) {}
web_place :: proc(app: ^App, x, y, w, h: int, visible: bool) {}
