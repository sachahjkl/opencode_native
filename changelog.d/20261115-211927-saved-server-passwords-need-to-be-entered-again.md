type: Changed

**Saved server passwords need to be entered again**: passwords are now sealed by the shared store of the toolkit (Windows DPAPI, the Secret Service on Linux) in a new format. Open each saved server that had a password and enter it again. On Linux, the old keyring item labelled "opencode native: <server>" is no longer used and can be deleted.
