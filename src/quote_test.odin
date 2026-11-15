package ocn

import "core:fmt"
import "core:strings"
import tk_json "gt:json"

// (the quoting itself is the toolkit's, tested in its tests/json)

// A prompt's body as the interface's thread made it before (prompt_fields as it was): the reference of prompt_body.
prompt_body_reference :: proc(text: string, attachments: []Attachment, mentions: []Mention, fields: string) -> string {
	files := strings.builder_make(context.temp_allocator)
	agents := strings.builder_make(context.temp_allocator)
	for a in attachments {
		if strings.builder_len(files) > 0 { strings.write_byte(&files, ',') }
		fmt.sbprintf(&files, `{{"uri":%s,"name":%s}}`, tk_json.quote(a.uri), tk_json.quote(a.name))
	}
	for &m in mentions {
		mention, ok := mention_json(&m, text)
		if !ok { continue }
		list := m.kind == .File ? &files : &agents
		if strings.builder_len(list^) > 0 { strings.write_byte(list, ',') }
		if m.kind == .File {
			fmt.sbprintf(list, `{{"uri":%s,"name":%s,"mention":%s}}`, tk_json.quote(m.target), tk_json.quote(m.name), mention)
		} else {
			fmt.sbprintf(list, `{{"name":%s,"mention":%s}}`, tk_json.quote(m.target), mention)
		}
	}
	out := ""
	if strings.builder_len(files) > 0 { out = fmt.tprintf(`,"files":[%s]`, strings.to_string(files)) }
	if strings.builder_len(agents) > 0 { out = fmt.tprintf(`%s,"agents":[%s]`, out, strings.to_string(agents)) }
	return fmt.tprintf(`{{"text":%s%s%s}}`, tk_json.quote(text), out, fields)
}
