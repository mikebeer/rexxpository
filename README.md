# RXPIP — a package manager for REXX

RXPIP is a pip-style package manager for classic REXX programs. It has two
halves:

- **Server** (`server/rxpip_server.rexx`) — a CGI script that serves a
  package repository over HTTP(S). Runs under Apache/mod_cgi on
  `www.rexxpository.org`. Written once, in Regina — see
  [ARCHITECTURE.md](ARCHITECTURE.md) for why one server implementation is
  enough to support every REXX runtime.
- **Client** (`client/rxpip.rexx`, invoked as `rxpip`) — the command-line
  tool developers run locally to install, publish, and use packages.

A REXX program declares what it needs with a comment convention:

```rexx
/* REQUIRE mathutils */
/* REQUIRE greetutils */
```

and `rxpip run yourprogram.rexx` resolves and installs anything missing,
then runs it.

## Quick start

**Linux / macOS:**

```bash
export RXPIP_HOME=~/.rxpip          # optional, this is the default
rxpip config set REPO_URL https://www.rexxpository.org/cgi-bin/rxpip_server.rexx
```

`client/rxpip.rexx` is executable and has a `#!/usr/bin/regina -a`
shebang, so `chmod +x client/rxpip.rexx` and running it directly
(`./rxpip.rexx ...`) works, or invoke explicitly with `regina -a
client/rxpip.rexx ...`. The `-a` matters — see the note on argument
handling in ARCHITECTURE.md.

**Windows:**

```powershell
set RXPIP_HOME=%USERPROFILE%\.rxpip     REM optional, this is the default
rxpip config set REPO_URL https://www.rexxpository.org/cgi-bin/rxpip_server.rexx
```

Use `client/rxpip.bat` (put it on `PATH` alongside `rxpip.rexx`, or run
it from the `client\` directory) so plain `rxpip ...` works the same
way as on Linux/macOS. Needs Regina for Windows on `PATH`, plus
`tar.exe`/`curl.exe` — both ship in `System32` on Windows Server 2019+
and Windows 10 1803+; on older hosts, Git for Windows bundles
compatible versions of both. See DEPLOY.md's Windows testing section
for a checklist — the Windows code paths are implemented but, absent a
Windows host during development, not yet executed, so please verify
before relying on them.

Once configured (either platform):

```bash
# use a package manager
rxpip search math
rxpip show mathutils
rxpip install mathutils
rxpip install greetutils==1.0.0
rxpip list
rxpip freeze > requirements.txt
rxpip uninstall mathutils

# the REQUIRE workflow
rxpip run myprogram.rexx arg1 arg2      # auto-installs deps, then runs
rxpip build myprogram.rexx --output=out.rexx   # same, but writes a
                                                # standalone file instead
                                                # of running it

# publishing
rxpip publish mypkg-1.0.0.rxpkg \
  --name=mypkg --version=1.0.0 --author=me \
  --summary="what it does" --requires="otherpkg>=1.0.0" \
  --token=some-shared-secret
```

`rxpip help` lists every command.

## Why `rxpip run`/`rxpip build`, not just `install`?

Classic REXX interpreters — Regina included — do **not** auto-discover
external routines by scanning the current directory for a file matching
the routine's name. (We tested this directly: even with a properly
executable, correctly-cased file sitting right there, an unresolved call
just falls through to the shell.) So `install`/`scan` alone only fetch
files into `~/.rxpip/lib/`; they don't make a `/* REQUIRE */`-d routine
callable by themselves.

`run` and `build` solve this the portable way: they concatenate your
script's source with a safety `EXIT` and then the source of every
installed package file, producing one ordinary, self-contained REXX
program where every required routine is just another internal label.
This works identically on any classic-REXX interpreter — no OS-specific
search-path tricks, no shell involved, no per-call process spawning.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design writeup,
including a documented (but deliberately *not* used) alternative — REGINA
does have a PATH-based external-command fallback, but it turns out to be
shell-injection-vulnerable and unreliable in ways that make it unsuitable
for a general-purpose package manager. Worth knowing about; not what
RXPIP uses.

## Package format

A package is a `.rxpkg` file — a plain `tar.gz` of one or more `.rexx`
source files:

```
mathutils.rexx
```

```rexx
/* mathutils.rexx */
Square: procedure
  parse arg n
  return n * n
```

**Gotcha to know about:** don't name an exported routine the same as a
REXX built-in function (`Reverse`, `Date`, `Random`, …). REXX identifier
lookup is case-insensitive and checks routine labels *before* built-ins,
so a routine called `Reverse:` silently shadows — and recursively calls —
the built-in `REVERSE()`, which segfaults the interpreter. We hit this
exact bug writing the example packages; see `examples/strutils/`.

## Repository layout on this checkout

```
server/rxpip_server.rexx   the CGI server (Regina)
client/rxpip.rexx          the rxpip CLI (Regina; invoke with `regina -a`,
                            or chmod +x and run directly — see shebang)
examples/                  example packages + a demo program using REQUIRE
ARCHITECTURE.md            protocol, artifact model, and design rationale
DEPLOY.md                  how to stand up the server on Apache
```

## Status

Everything above is implemented and was tested end-to-end against a real
HTTP server (Python's CGI handler standing in for Apache during
development; behavior against Apache itself is covered by
[DEPLOY.md](DEPLOY.md)'s notes on header forwarding and process
ownership). Supported today: Regina. See ARCHITECTURE.md for the
multi-runtime story and current state of cREXX, ooRexx, and NetRexx
support.
