# RXPIP architecture

## 1. The core design decision: one server, many runtimes via metadata

The original brief asked for the server to be implemented in both Regina
and cREXX ("all main REXX versions"). We built and fully tested a Regina
implementation, then investigated what a cREXX port would actually
require (§4). The short version: modern cREXX is not a classic-REXX
interpreter you can port classic source to — it's a different, typed,
compile-to-bytecode language, and its classic-REXX compatibility mode
doesn't yet support basic control flow (`DO`, `IF`) at all.

Rewriting the server once per interpreter doesn't scale anyway — it was
already the wrong shape for a package manager that's supposed to make
REXX's fragmentation *less* painful, not more. So instead:

- **The server is implemented once**, in Regina, and stays that way.
- **Packages declare what they contain, not what interpreter it's for.**
  Every published package version can carry one or more **artifacts**:

  | Field | Meaning |
  |---|---|
  | `KIND` | `SOURCE` — portable classic-REXX source (the default, and the only kind most packages will ever need), or `BYTECODE` — a precompiled artifact for one specific runtime. |
  | `PLATFORM` | `any` for `SOURCE` artifacts, or a specific tag like `crexx-linux-x86_64` for `BYTECODE`. |

  A publisher ships a `SOURCE/any` artifact by default. If a specific
  runtime later benefits from a precompiled form (once, say, cREXX's own
  toolchain is the publishing tool), the publisher can *additionally*
  publish a `BYTECODE` artifact for that platform, without touching the
  `SOURCE` one. The client resolves the best match for its own platform
  tag (`<interpreter>-<os>-<arch>`, e.g. `regina-linux-x86_64`),
  preferring an exact `BYTECODE` match and falling back to `SOURCE/any`
  — which is guaranteed to exist and guaranteed to work everywhere,
  because RXPIP's `run`/`build` commands turn `SOURCE` artifacts into
  ordinary, self-contained programs through source concatenation (§3),
  not through any interpreter-specific loading mechanism.

This was tested end-to-end: a fictitious `BYTECODE/crexx-linux-x86_64`
artifact was published alongside a real `SOURCE/any` one for the same
package version, and `ARTIFACTS`/`INFO`/`DOWNLOAD` all handled both
correctly, independently, with their own file lists.

## 2. Wire protocol

Plain RFC822-style "stanza" text over HTTP(S) — chosen over JSON because
every classic-REXX interpreter can `PARSE` fixed `KEY: value` lines with
zero external libraries, and none can be assumed to have a JSON parser.

```
GET  ?action=PING
GET  ?action=LIST
GET  ?action=SEARCH   &q=<term>
GET  ?action=INFO     &name=<pkg>  [&version=<ver>]
GET  ?action=VERSIONS &name=<pkg>
GET  ?action=ARTIFACTS&name=<pkg>  [&version=<ver>]
GET  ?action=DOWNLOAD &name=<pkg>  [&version=<ver>] [&kind=..] [&platform=..]
GET  ?action=OWNERS   &name=<pkg>
GET  (no action)  HTML package index + search (?q=); ?action=PKG&name=<pkg> HTML package page
POST ?action=PUBLISH  (raw artifact bytes as body; metadata via
                        X-Rxpip-* headers, or query-string params as a
                        fallback -- see §5; the token ONLY in the
                        X-Rxpip-Token header)
POST ?action=REGISTER (X-Rxpip-Invite, X-Rxpip-User) -> first token
POST ?action=WHOAMI | TOKENS | NEWTOKEN | REVOKE | ADDOWNER | REMOVEOWNER
                       (X-Rxpip-Token header required)
```

Errors for the mutating actions use real HTTP status codes (400, 401, 403,
404, 405, 409, 413) as well as the `STATUS: ERROR` / `CODE:` body.

Non-download responses:

```
STATUS: OK
COUNT: <n>

NAME: mathutils
VERSION: 1.0.0
AUTHOR: jdoe
SUMMARY: Math utility functions for REXX
REQUIRES:

... (repeated stanza per record, blank-line separated)
```

`DOWNLOAD` streams the raw artifact bytes with normal `Content-Type:
application/octet-stream` / `Content-Length` headers.

## 3. Why `run`/`build` concatenate source instead of relying on the
   interpreter to find installed routines

We assumed, going in, that classic REXX interpreters auto-discover
external routines by scanning the working directory for a file matching
the routine's name. **This is false**, at least for Regina, and we proved
it by direct experiment before designing around it:

```rexx
/* caller.rexx, with Square.rexx sitting right there in the same dir */
say Square(7)
```
```
$ regina ./caller.rexx
sh: 1: SQUARE: not found
```

Instead: an unresolved call falls through to the **host shell**. There
*is* a working mechanism here — if a file named `SQUARE` (uppercase,
matching how REXX folds symbols), executable, with a shebang, sits on
`$PATH`, the call succeeds and the external program's **stdout** (not its
`RETURN` value — that only sets the exit code) becomes the function's
result, for both function-call and `CALL`-statement forms. We verified
all of this concretely. We also verified it's **not safe to build on**:
passing `'hello; rm -rf ... && echo pwned'` as an argument through this
path executes the injected shell command, because argument marshalling
goes through an unescaped shell command line. It also spawns a full
interpreter process per call and can't bundle multiple routines in one
file. So RXPIP documents this mechanism (you now know it exists) but
does not use it.

What RXPIP actually does, in `rxpip run` and `rxpip build`:

1. Scan the target script for `/* REQUIRE pkg[>=version] */` comments and
   auto-install anything missing (into `~/.rxpip/lib/`, flattened).
2. Concatenate: the original script's source, then a safety `EXIT`
   (so normal top-to-bottom execution can never fall through into what
   follows), then the source of every installed package file.
3. The result is one ordinary REXX program. Every `/* REQUIRE */`-d
   routine is now just another internal label in the same compiled
   program — completely normal, portable REXX call resolution, no
   filesystem search, no shell, no per-call overhead.

`run` does this into a temp file, executes it, and cleans up. `build`
does the same but writes a permanent, shareable, standalone `.rexx` file
that needs nothing else installed to run — we verified this explicitly,
running the `build` output with plain `regina`, RXPIP totally absent from
the picture.

**Known limitation:** if two installed packages both define a routine
with the same internal-label name, whichever the interpreter resolves
first wins (REXX permits duplicate labels; behavior across interpreters
for *which* one wins is not something we're relying on). Package authors
should give exported routines names unlikely to collide — and, per the
gotcha in the README, never a name that collides with a REXX built-in.

## 4. cREXX: what we found, and why the server doesn't target it directly

We didn't want to guess about this, so we cloned and **built the actual
cREXX toolchain from source** (`adesutherland/CREXX`, `cmake` + `gcc`,
~20 minutes) and tested against it directly rather than against
documentation alone.

Finding: **modern cREXX is not a classic-REXX interpreter.** It's a
compile-to-bytecode toolchain (`rxc` → `rxas` → `rxvm`) built around a
new, typed, module/namespace-based dialect called **Level B**:

```
options levelb
import rxfnsb

sum: procedure = .int
  arg first = .int, ... = .int
  ...
```

It does have a documented "Level C / Classic REXX compatibility" mode
with a `.rexx` source convention — the thing that would, in principle,
let our Regina scripts run unmodified. We tested it directly, one
construct at a time:

| Construct | Compiles under cREXX Level C? |
|---|---|
| `say 'hello'` | yes |
| `a.1 = 'x'; say a.1` (simple stem) | yes |
| `Foo: procedure` (called via `CALL`) | yes |
| `Foo:` (plain label, no `PROCEDURE`) | **no** |
| `do i = 1 to 3 ... end` | **no** — "unsupported main statement" |
| `if 1=1 then say 'yes'; else say 'no'` | **no** — same error |

Even basic `DO` loops and `IF/THEN/ELSE` aren't implemented in classic
compatibility mode yet. This isn't a fluke of our test environment —
cREXX's own documentation says so explicitly:

> "Level C is where Classic compatibility work belongs, and normal Level
> C compilation is not a beta 3 contract unless the beta 3 release notes
> explicitly say otherwise."

**Consequence for RXPIP:** there is currently no viable way to run our
Regina-style server or client source under cREXX. A genuine cREXX
implementation would mean writing a second, structurally different
program in Level B's typed/module dialect — a real, separate project, not
a port. The artifact model in §1 is exactly what makes this *not
block anything*: RXPIP's protocol and server are already ready for a
future `BYTECODE/crexx-*` artifact kind, or for a native Level B client,
whenever that's worth building. Today, `SOURCE/any` is what every
package should publish, and it's what every user gets by default.

The same reasoning applies to ooRexx and NetRexx, which we have not yet
tested hands-on: RXPIP's server and artifact model don't need to change
to accommodate them, only (potentially) their own client and/or
`BYTECODE` artifacts, if and when that's worth doing.

## 5. Implementation gotchas worth knowing (found via direct testing)

These cost real debugging time and are worth recording so they don't get
rediscovered the hard way:

- **Cross-procedure stem "output parameters" don't reliably work.**
  Regina's indirect `EXPOSE (var)` did not share a stem back to the
  caller the way TRL2-style examples suggest. Every helper routine in
  both scripts instead returns a single delimited string (`'01'x`field
  separators, `'0a'x` record separators) via ordinary `RETURN` — fully
  self-contained, no cross-frame variable sharing, and portable.
- **`RANDOM()` caps its range at 100000** in Regina —
  `random(1,999999)` throws `Error 40.32`.
- **`CHARIN()` can't take a start-position argument on STDIN** (it's not
  seekable): `charin(,1,len)` fails with "cannot position on this
  stream"; must be `charin(,,len)`.
- **`PARSE ARG` joins the whole command line into one string by
  default**, silently destroying word boundaries inside a quoted
  multi-word value (`--summary="a description with spaces"` arrives
  truncated at the first space). Fixed by running under `regina -a`
  (`--args`, "pass command line to Rexx program as separate arguments")
  and rebuilding the argument list from individual `ARG(n)` elements,
  rejoined internally with `'01'x` so downstream parsing still gets to
  work with a simple delimited string. Forwarding those arguments on
  again through a shell command line (in `rxpip run`) needed its own
  fix: proper POSIX single-quote shell-quoting per argument, not a
  plain space-rejoin, or embedded spaces/quotes get re-split by the
  shell a second time.
- **Comma line-continuation is not concatenation.** `expr1 ,` followed
  by `expr2` on the next line parses as `expr1 expr2` — i.e. *blank*
  concatenation (a REXX abuttal, same as `say 'a' 'b'`) — not `expr1 ||
  expr2`. Building a URL or shell command across multiple lines this way
  silently inserts stray spaces (`...PUBLISH &name=...` — invalid as a
  query string). Fix: end each continued line with `||,` so the `||` is
  the operator actually joining the two expressions, and the comma is
  purely the (separate) line-continuation signal.
- **A routine name that collides with a REXX built-in function
  recursively calls itself.** REXX identifier resolution is
  case-insensitive and checks routine labels before built-ins; a routine
  literally named `Reverse:` that calls `reverse(s)` inside it calls
  *itself*, infinitely, and segfaults the interpreter. See §3 and the
  README.
- **Testing PUBLISH's write path against a root-run Python CGI test
  server can misleadingly fail:** Python's `http.server` drops
  privileges to `nobody` before exec'ing a CGI script when launched as
  root, so writes to a root-owned repo directory silently fail with
  "Permission denied" even though the *protocol* is working correctly.
  This is a property of the test harness, not of the design — see
  DEPLOY.md for what the equivalent, correct setup looks like under
  Apache.
- **Not every CGI handler forwards custom request headers.** Python's
  `CGIHTTPRequestHandler` only forwards a small header whitelist
  (`Accept`, `Cookie`, `Referer`, `User-Agent`) — a real constraint of
  some deployments, even though Apache/mod_cgi forwards all headers as
  `HTTP_*` env vars per the CGI spec. `PUBLISH` metadata is therefore
  accepted via **both** `X-Rxpip-*` headers and query-string parameters
  (headers win if both present), so the protocol doesn't have a single
  point of fragility here.

## 6. Cross-platform support: Windows, Linux, macOS

The client must run on all three; the server is tested primarily on
Linux but is also expected to run on Windows (the repository's own test
cycle runs Regina on a Windows Server host). Both scripts route every
filesystem/archive/process operation through a small OS-portability
layer at the bottom of each file (`IsWindows`, `TempDir`, `NullSink`,
`DelFile`, `DelTree`, `MoveFile`, `CopyFile`, `EnsureDir`, and, in the
client, `RunInDir`) rather than scattering `mkdir -p`/`ls -1`/`rm -f`
-style Unix shell-outs through the rest of the logic. Everything above
that layer — protocol parsing, stanza handling, the artifact model,
dependency resolution — is identical on every platform; only *how we
shell out* differs, and it differs in exactly one place per operation.

**What this required, concretely:**

- **OS detection.** No REXX built-in for this is portable across
  interpreters, so it's done via environment variables Windows always
  sets and Unix normally doesn't: `OS=Windows_NT` and `COMSPEC`.
- **Temp files.** `/tmp/...` doesn't exist on Windows; `TempDir()`
  resolves `%TEMP%`/`%TMP%` instead.
- **`$HOME`.** Windows doesn't set `HOME` by default; the client falls
  back to `%USERPROFILE%`.
- **Directory listing, mkdir, delete, move, copy.** `ls -1` → `dir /b`;
  `mkdir -p` → `mkdir` (Windows' `mkdir`/`md` already creates
  intermediate directories, so no `-p` equivalent is needed — just
  suppressing the "already exists" error); `rm -f`/`rm -rf` →
  `del /f /q`/`rmdir /s /q`; `mv`/`cp` → `move /y`/`copy /y`.
  "Is this a directory?" uses the `if exist "path\"` idiom (a trailing
  backslash specifically tests for a directory in `cmd.exe`) rather
  than POSIX `[ -d ... ]`.
- **`cd X && Y`.** Works the same in `cmd.exe`, except changing drive
  letter needs `cd /d`, so `RunInDir` adds that switch on Windows.
- **Shell quoting.** This is the one place the two platforms are
  *structurally* different, not just syntactically. POSIX single-quotes
  make everything inside them literal, full stop — `ShellQuote`'s Unix
  branch just wraps in `'...'` and escapes embedded `'` as `'\''`.
  `cmd.exe` has **no single-quote string syntax at all** (a `'` is just
  an ordinary character there); the Windows branch wraps in `"..."` and
  doubles embedded `"` instead. This is adequate for ordinary text and
  paths. It is a known, not-fully-solved risk for values containing
  `cmd.exe`'s own metacharacters (`&`, `|`, `<`, `>`, `^`, `%`), because
  `cmd.exe` parses a command line in a layer *before* the target
  program's own argv parsing, and getting both layers right
  simultaneously is one of the genuinely hard parts of Windows scripting.
  If you hit this, prefer avoiding those characters in arguments passed
  through `rxpip run` on Windows for now.
- **Source concatenation (`MergeScript`, the heart of `run`/`build`).**
  Unix builds the merged program with a `cat`/`echo` subshell whose
  combined output is redirected to the output file; the Windows branch
  uses the equivalent `TYPE`/`ECHO` sequence joined with `&`
  (unconditional-next) rather than `&&` (only-on-success), specifically
  so an empty `lib/` directory — `TYPE` on a non-matching wildcard exits
  non-zero — doesn't abort the whole sequence on either platform.
- **`tar` and `curl`.** Left unchanged across platforms deliberately:
  Windows 10 1803+ and Windows Server 2019+ ship a bsdtar-compatible
  `tar.exe` and a real `curl.exe` in `System32`, both accepting the same
  command-line syntax used here. On an older Windows host without these
  on `PATH`, install compatible builds (e.g. via Git for Windows, which
  bundles both) and no script changes are needed.
- **`PlatformTag()`.** Avoids shelling out to `uname` on Windows
  entirely — `PROCESSOR_ARCHITECTURE` is already in the environment.

**Bugs this surfaced, found only by actually testing the refactor (all
fixed, all on the Linux side where they're verifiable):**

- Moving the `cd X && interp ...` invocation into a separate `RunInDir`
  procedure broke exit-code propagation: `RunInDir` is an isolated
  `procedure`, so the `RC` its embedded command set was never visible
  to its caller afterward (the same class of scoping issue as the
  stem-`EXPOSE` gotcha in §5 — anything set by a host command inside an
  isolated procedure is local to that procedure unless explicitly
  `RETURN`ed). Fixed by having `RunInDir` `RETURN rc` and having the
  caller use `runrc = RunInDir(...)` instead of reading `rc` itself
  afterward.
- Testing the fix above surfaced an unrelated, pre-existing correctness
  gap: `InstallOne`'s "already installed, nothing to do" early return
  skipped checking whether that package's *dependencies* were still
  present. Uninstalling a shared dependency (`strutils`) and then
  re-running a program that required a package depending on it
  (`greetutils`) silently ran with the dependency missing, because
  `greetutils` itself being "already installed" short-circuited before
  its `REQUIRES` were ever re-examined. Fixed: the already-installed
  branch now still walks and verifies/installs its recorded
  dependencies before returning, using the locally recorded `REQUIRES`
  metadata rather than a network round-trip.

**Honesty about test coverage.** The Linux code paths in this project
are extensively tested end-to-end, including through real HTTP against
a live CGI server. The Windows code paths described above were written
carefully and cross-checked against documented `cmd.exe`/Windows
behavior, but **could not be executed in this environment** — there is
no Windows host available here. Treat them as a solid, reasoned-through
first implementation that needs real verification on an actual Windows
box before you rely on it, and see the checklist in DEPLOY.md for
exactly what to check first.

## 7. Security notes

- Package/version/kind/platform tokens are validated server-side against
  a strict allow-list (`IsSafeToken`/`IsSafeVersion`/`IsSafeKind`) before
  ever touching a filesystem path, specifically to block path traversal
  (`../../etc` is rejected, tested directly).
- **Accounts and tokens.** Publishing needs a user account. Accounts are
  created only from single-use invite codes issued by the operator on the
  server (`rxpip_server.rexx admin ...`, which is entered only when
  `GATEWAY_INTERFACE` is unset and so is unreachable through CGI). Tokens
  are `rxp_<8 hex id>_<48 hex secret>`, generated by the server from
  `/dev/urandom` (the server refuses to create accounts if secure
  randomness or SHA-256 is unavailable; there is no weak fallback), shown
  once, and stored as `sha256$<salt>$<hash>`. Because the secrets are
  192-bit random values rather than human-chosen passwords, a single
  salted SHA-256 is adequate; a slow KDF would only matter for passwords.
- **Secrets never touch URLs or command lines.** The server rejects a
  token in the query string (`TOKEN_IN_URL`, since URLs are logged);
  secrets reach child processes (`sha256sum`, file writes) via environment
  variables, not arguments; the client hands tokens to `curl` through a
  private header file (`curl -H @file`) and keeps its saved token in a
  mode-600 file. Responses that carry a secret are `Cache-Control: no-store`.
- **Ownership.** The first publish of a name claims it (atomic exclusive
  create on Unix; one of two concurrent claimants wins, tested). Owners are
  a per-package list; any owner may add or remove owners, never the last.
- **Uploads.** `RXPIP_MAX_UPLOAD` (default 5 MiB) is enforced before the
  body is read. Archives are validated before anything is kept: at most
  200 members, regular files only (no symlinks, hardlinks, devices or
  directories), flat safe file names. Uploads are staged in `repo/.staging`
  and moved into place atomically; a rejected upload leaves no trace and
  does not claim the name. Releases are immutable (409 on re-publish).
- **Metadata.** Free-text fields are length-capped and may not contain
  control characters (a newline in a summary used to inject fake fields
  into `PACKAGE.META`). `version` is validated wherever it reaches a file
  path (INFO, ARTIFACTS and DOWNLOAD once did not; fixed).
- **Web front end.** Server-rendered HTML; every metadata value is
  HTML-escaped, and a `Content-Security-Policy` of `default-src 'none'`
  forbids scripts and external loads regardless.
- **Known gaps:** no rate limiting, no typosquat/reserved-name policy, no
  yank/delete over HTTP, last-writer-wins on simultaneous owner-list
  edits, and the Windows branches (PowerShell hashing/randomness,
  non-atomic claims) are untested. See DEPLOY.md §13.
- The client never runs anything through an unescaped shell string built
  from untrusted network data without quoting (see the `ShellQuote` fix
  in §5); package *content* itself is of course still trusted at the
  same level as any other code you choose to install and run.

## 8. The four clients

All clients speak the same wire protocol and print the same messages, so
one test scenario (`tests/run_client_matrix.sh`) covers them all.

| Client | Language specifics |
|---|---|
| Regina `client/rxpip.rexx` | The reference client. `run` merges your script and the installed `.rexx` files into one program (§3). |
| ooRexx (same file) | Launcher `rxpip-oorexx` double-quotes every argument because ooRexx passes the command line as one string; `rxpip.rexx` splits it again (`SplitQuoted`). `run` starts the merged program through a generated runner that calls it with real separate arguments (`.routine~callWith`). Status lines are parsed with `StanzaField`, not `word()`, because ooRexx (correctly) does not treat a newline as a blank. Shares the `~/.rxpip` package store with Regina. |
| NetRexx `client/netrexx/Rxpip.nrx` | One class; `ProcessBuilder` starts curl/tar (no shell). Installs `SOURCE/netrexx` packages (`.nrx`, one class per file). `run` compiles your program together with the installed `.nrx` classes with NetRexxC and runs it; `build` writes a jar. State in `~/.rxpip/netrexx/`. The launcher compiles `Rxpip.nrx` on first use. |
| cREXX `client/crexx/rxpip.crexx` | Level B. Installs `SOURCE/crexx` packages (`.crexx` modules with a `namespace`). `run` compiles user program and modules with `rxc -s <dir>`, assembles with `rxas`, starts `rxvm prog mod... -a args`. Uses `ADDRESS CREXX "run :argv[]"` (argument vector, no shell). State in `~/.rxpip/crexx/`. |

**Platform tags.** `SOURCE/any` is classic REXX source (Regina and ooRexx).
NetRexx and cREXX packages are published with `--platform=netrexx` /
`--platform=crexx`, and each client installs only artifacts matching its
language, so a package name can carry artifacts for several languages.

**Secrets** go to curl through a private header file (`-H @file`, mode 600,
removed right after the call) in every client — never on a command line.

**Not run yet:** the Windows launchers (`.bat`) and macOS for the
NetRexx, cREXX and ooRexx clients; everything here ran on Linux.

## 9. Moderated web sign-up

`?action=SIGNUP` takes name, e-mail and location and stores a pending
request (`.auth/requests/<id>.req`, secret kept as a salted hash). The
administrator receives a mail with `?action=REVIEW&req=…&key=…`. A GET on
that link only shows the request; approving or rejecting is a POST, so
mail scanners that prefetch links change nothing. Approval creates a
single-use invite and mails it to the applicant (which also proves the
address). Limits: 100 pending requests, 3 per IP, expiry after 14 days,
honeypot field, strict validation of every field (no control characters
reach a mail header). Off unless `RXPIP_ADMIN_EMAIL` is set; mail is sent
through `sendmail` (or `RXPIP_SENDMAIL`).

## 10. Install scopes and storage backends

`install`, `uninstall`, `list`, `freeze` and `scan` act on a *scope*:
the current directory by default (files in it, record in
`./.rxpip/installed.txt`), `--global` for the shared store under
`~/.rxpip`, `--target DIR` for another directory. `run`/`build` always
merge the shared store. `rxpip find [dir…] [--sync]` collects the records
below some roots and the shared store, shows duplicates and copies older
than the newest version found, and with `--sync` upgrades them in place.
A package file that exists in the target but is not in the package's own
record is never overwritten without `--force`.

In the Regina/ooRexx client everything that knows *where* things live is
one section ("Storage backends"): `RecLoad`/`RecSave` (record text of a
scope), `StoreExists`/`StoreCopyIn`/`StoreDelete`/`StoreMake` (package
files). The registry (find, remove, record, summary) works on the record
text only. A new environment supplies these routines and `SetScope`.

### Private packages and the closed repository

Per package, under `.auth/` (never served): `visibility/<pkg>.vis` (present
and `private` = hidden) and `readers/<pkg>.readers` (users allowed to read
besides the owners). Reads carry the token in `X-Rxpip-Token`; `Viewer()`
turns it into a user, `CanRead()` decides, and every read action asks it. A
hidden package yields the same answer as a missing one (404 / `NOT_FOUND` /
`COUNT: 0`), so names cannot be probed. `RXPIP_CLOSED=1` adds a gate in front
of every read (`NO_TOKEN`, HTTP 401). The visibility is stored before the
first artifact of a new private package is moved into place, so it is never
readable even briefly. A public package may not require a private one. The
clients read the token once at start (`--token`, `RXPIP_TOKEN`, saved login)
and pass it to curl through the same private header file as for publishing.

### Client versions, statistics and the administrator role

Clients send `X-Rxpip-Client: <kind>/<version> (<os>)` (a request header; the
server only logs it). The server writes `repo/.stats/<yyyymmdd>.log`:
`time|REQ|action|kind|version|os|uid` for each request except PING and the web
pages, plus `DL`/`PUB` lines with package, version and artifact. `uid` is
`left(sha256(REMOTE_ADDR|day|salt),12)`, with a random salt in `.stats/salt`,
so ids do not link across days and hold no address. Pruning (400 days) runs when
a new day's file is created. `RXPIP_NOSTATS=1` disables logging.

Client releases: `repo/.clients/<kind>/<ver>/{files,MANIFEST}` and
`<kind>/LATEST` (only moves forward). `CLIENT` (public GET, works in closed mode)
returns the manifest (`VERSION LATEST MIN FILES`) or one file named in the
manifest. `ADMINCLIENT` (POST, admin) takes a tar.gz validated by
`ValidateArchive` (flat safe names) and refuses an existing version.

The administrator role is a list in `.auth/admins`; `AuthenticateAdmin` = normal
token auth + membership (403 otherwise). Admin HTTP actions: `ADMINSTATS`,
`ADMINUSERS`, `ADMINLOCK`, `ADMINCLIENT`. Local CLI: `addadmin`, `rmadmin`,
`admins`, `stats`.

Client side: `update [--check]` downloads each file as `<name>.new` and moves
them over the old ones only when all arrived (refused over plain http except
127.0.0.1/localhost); NetRexx/cREXX also delete their compiled output so the
launcher recompiles. The client finds its own folder from `RXPIP_CLIENT_DIR`
(set by the launchers; Regina falls back to `parse source`). A once-a-day check
(stamp `clientcheck.txt`) prints a hint on stderr (cREXX: stdout, not before
`run`).

### Removing the Internet mark from what rxpip downloads

`Unblock(path)` (Regina/ooRexx; `unblock` in NetRexx/cREXX) removes the
"downloaded from the Internet" attribute -- Windows `Zone.Identifier`, macOS
`com.apple.quarantine` -- from the package archive before it is unpacked, from
the unpacked tree under the client home, and from the files of a client update
before they replace anything. REXX scripts are run by the interpreter and are
never blocked, but binaries, DLLs and `.so` files in a package are. Windows:
`dir /s /r` is a cheap test for the stream, and only if it is present PowerShell
`Unblock-File` runs; macOS: `xattr -dr`; Linux does nothing. Every failure is
ignored. `curl` does not set the mark itself, so this matters mainly when the
files travel through a browser, a shared drive or a scanner before rxpip gets them.

### Signed client releases

A release may contain `<file>.minisig` next to `<file>` (minisign, Ed25519). The
server just stores them as ordinary release files (they are in `FILES`) and the
download page links them and shows the public key (`MinisignKey()`, default the
project key, `RXPIP_MINISIGN_KEY` overrides). Trust lives in the client:
`rxpip update` downloads everything as `.new`, then `VerifyRelease` runs
`minisign -V -q -P <key> -m f.new -x f.minisig.new` for each signed file before any
file is moved. Result: OK / UNSIGNED / NOTOOL (minisign missing) / FAIL (always
refuses, deletes the `.new` files). Config `REQUIRE_SIGNATURE 1` also refuses
UNSIGNED and NOTOOL. The key is built into all four clients and
`RXPIP_MINISIGN_KEY` overrides it (tests, key rotation). The private key never
touches the server.

### VM/370plus

*Existing route.* mikebeer/vm370plus (`arch/31bit/linux390/rxpip`) already
serves CMS users through a spool bridge: `RXPIP.EXEC` on CMS sends a
request to a vmspoold service in the Debian guest, which runs this
Regina client against a local repository and returns the merged program
(`RXPIP BUILD/RUN`) or the package sources (`RXPIP GET`) as CMS files. The
bridge handler calls `rxpip install` for `GET`; with install-to-current-
directory as the default it should call `rxpip install --global`, or the
packages also land in the service's working directory.

*Native route (below).* If a REXX on CMS should ever run the client
itself, the storage section already has the hooks. The skeleton is
untested and may never be needed while the bridge works.

### Planned native CMS backend (skeleton only)

The target has no directories, file names of at most 8.8 characters
(name, type), and uses GLOBALV like an ini file. BREXX and cREXX run
there; a TCP/IP client is expected, and packaging for the platform is
done elsewhere. The skeleton in the Regina client maps the model as:

| model            | directories (now)           | CMS (planned)                          |
|------------------|-----------------------------|----------------------------------------|
| scope            | a directory                 | a minidisk filemode (`A`, `B`, …)      |
| package files    | files in the directory      | `NAME TYPE <mode>` via COPYFILE/ERASE  |
| record           | `<dir>/.rxpip/installed.txt`| GLOBALV group `RXPIP`, variable `REC_<mode>` |
| shared store     | `~/.rxpip`                  | the disk named by `LIB_DIR`            |

Still open: GLOBALV value length limits (the skeleton keeps a whole
record in one variable, line ends turned into `|`; one variable per
package may be needed), how package files reach the work disk (network
fetch by the TCP/IP client, or a protocol on a service engine), the 8.8
rule for package and file names (to be enforced when a package is
published for the CMS platform tag), and `find` (iterate the GLOBALV
group). None of the CMS routines has been run.
