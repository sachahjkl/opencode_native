// No web view on Linux yet: links go to the system's browser (preview.odin asks web_available first).
package ocn

web_available :: proc() -> bool { return false }
web_host_system :: proc() -> Web_Host { return {} }
