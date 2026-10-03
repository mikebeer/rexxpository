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
POST ?action=PUBLISH  (raw artifact bytes as body; metadata via
                        X-Rxpip-* headers, or query-string params as a
                        fallback -- see §5)
```

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
- Publishing uses a simple first-publish-claims-ownership shared-token
  model (`.auth/<name>.owner`), tested for both the happy path and a
  wrong-token rejection. This is intentionally minimal — real deployment
  should consider it a starting point, not a complete auth story (no
  token rotation, no per-user accounts, no rate limiting).
- The client never runs anything through an unescaped shell string built
  from untrusted network data without quoting (see the `ShellQuote` fix
  in §5); package *content* itself is of course still trusted at the
  same level as any other code you choose to install and run.
