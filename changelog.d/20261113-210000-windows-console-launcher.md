type: Added

**`opencode-native` can be used from a terminal on Windows**: when the install puts opencode native on the PATH, it also writes `opencode-native.com`. Then `opencode-native --help`, `--version` and `--status` print in cmd or PowerShell and give their exit code. The other command lines open the window and give the prompt back. The executable also runs with UTF-8 as its code page and accepts paths longer than 260 characters.
