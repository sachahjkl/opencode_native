# The servers' passwords

A saved server's password is sealed with the toolkit's `gt:secrets` (app `opencode-native`, the secret's name is the
server's name): DPAPI on Windows, the Secret Service on Linux. `servers.txt` keeps only the field that `seal` returned.
The toolkit decides how a secret is sealed; this file records what the program decides on top of it.

## Decisions

- **`Server.field` is always the file's field.** It is what the file holds for the password ("" for none), opened or
  not. The password in memory is `Server.password`. A field that could not be opened (a locked keyring, another account)
  is a server with a field and no password: it is kept as it is and read again at the next connection.
- **A save writes the new fields back to the servers.** A forget then names the item that the field really names, not
  the item that the server's name names. After a rename with a locked keyring, the two differ.
- **One forget, after the seals.** A server renamed or removed gives its old field to the save. The save forgets it once
  every password is sealed, unless a field just written is the same field: a server renamed back to the name of its
  item must keep it.
- **No store means a password in clear.** If `seal` is `Unavailable`, the field is the password, in a file that only the
  user can read, and the server dialog says so. The next save tries the store again. There is no failure path that
  keeps the old list.
- **A field in clear at the start is sealed at once** (`App.servers_in_clear`): the next save moves it to the store.
- **The program keeps whether the store answers.** `secret_available` asks `secrets.available` on a chore at most every
  five seconds and posts a frame when the answer changes; the dialog reads the cached answer in a frame.

## Refused

- **A migration of the fields of ocn's own store** (`dpapi:` without a version, `secret-service:v1` with the attribute
  `server`). A server saved with them has its password asked for again: the toolkit opens nothing of the old Linux
  items, and reads an old unversioned field as a value in clear.
- **A copy of the store in ocn** for an option that the toolkit lacks: the program asks nothing that `gt:secrets` does
  not give.
