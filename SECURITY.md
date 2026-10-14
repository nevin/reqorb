# Security

## Reporting a vulnerability

Please report it privately, through the repository's
[security advisory form](https://github.com/nevin/reqorb/security/advisories/new), not in
a public issue. Say what an attacker could do and how to reproduce it.

## What reqorb protects, and how

**Credentials at rest.** The workspace file is readable JSON, so every value that holds a
credential (secret variables and those named like one, credential headers, auth fields,
cookies, a proxy password) is encrypted with XChaCha20-Poly1305 before it is written. The
key is made on first use and kept only in the system keychain. On load, only those fields
are decrypted, so an encrypted value copied anywhere else stays encrypted. The workspace
and history files are written whole or not at all and are readable by their owner only.
On systems without a supported keychain, credentials are saved unencrypted and the app
says so.

**Collections kept as folders** leave credentials out of the files. Reading or writing a
folder never follows a symbolic link, so a cloned repository cannot point a request file
at another file on the machine.

**Requests.** Credential headers, including API-key headers, are not sent on to another
site when a request is redirected, unless a request's settings ask for that. Cookies set
for a public suffix such as `.com`, or marked `Secure` over plain HTTP, are refused. Files
a request sends can be confined to a working directory, checked by real path so that
neither `..` nor a link leads out of it.

**Scripts** run in an embedded JavaScript engine with no access to files, the network,
timers or the rest of the app. They see only the request, the response and the variables.
They are stopped after ten seconds, and the send stops waiting for them even where the
engine cannot interrupt them.

**The macOS app** runs in the App Sandbox. It can make network connections and open only
the files and folders the user chooses.

## What it does not protect against

- Scripts in a collection you import can read your variables, credentials included, and
  put them into the request being sent. Read the scripts of a collection from someone you
  do not trust before you send its requests.
- Unless a working directory is set, a request can send any file the app can read. An
  imported collection can name such a file.
- With certificate verification turned off in Settings, connections can be intercepted.
