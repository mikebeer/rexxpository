# Deploying the RXPIP server

Target: `www.rexxpository.org`, Apache + `mod_cgi` on Linux.

## 1. Install Regina

```bash
sudo apt-get install -y regina-rexx curl
```

`regina` must be on `$PATH` for the user Apache runs CGI scripts as
(normally `www-data`); the package install above puts it in
`/usr/bin/regina`, which is fine.

## 2. Lay out the repository

```bash
sudo mkdir -p /var/www/rexxpository.org/repo
sudo mkdir -p /var/www/rexxpository.org/cgi-bin
sudo chown -R www-data:www-data /var/www/rexxpository.org/repo
```

**The repo directory must be writable by the Apache user** — `PUBLISH`
creates directories and writes files under it. (During development we
tested against a minimal Python CGI server; running that as root
silently broke writes, because Python's CGI handler drops privileges to
`nobody` before exec'ing the script, and `nobody` couldn't write into a
root-owned directory. Reads worked, writes didn't, and the symptom was a
misleading-looking `STATUS: OK` response with nothing actually written.
Under real Apache this isn't automatic — you must deliberately make the
repo directory owned by, or writable by, `www-data`.)

## 3. Install the server script

```bash
sudo cp server/rxpip_server.rexx /var/www/rexxpository.org/cgi-bin/
sudo chmod +x /var/www/rexxpository.org/cgi-bin/rxpip_server.rexx
sudo chown www-data:www-data /var/www/rexxpository.org/cgi-bin/rxpip_server.rexx
```

## 4. Apache config

```apache
<VirtualHost *:443>
    ServerName www.rexxpository.org
    DocumentRoot /var/www/rexxpository.org/html

    ScriptAlias /cgi-bin/ /var/www/rexxpository.org/cgi-bin/
    <Directory "/var/www/rexxpository.org/cgi-bin">
        Options +ExecCGI
        AddHandler cgi-script .rexx
        Require all granted
    </Directory>

    SetEnv RXPIP_REPO_ROOT /var/www/rexxpository.org/repo

    # TLS config (certbot/Let's Encrypt or your own certs) goes here --
    # the client defaults to https:// and PUBLISH sends a shared-secret
    # token in a header, so this endpoint should not be served over
    # plain http in production.
</VirtualHost>
```

Enable the needed modules and reload:

```bash
sudo a2enmod cgid ssl
sudo systemctl reload apache2
```

`mod_cgid` (threaded MPM) or `mod_cgi` (prefork MPM) both work; use
whichever matches your Apache MPM.

## 5. Smoke test

```bash
curl -s "https://www.rexxpository.org/cgi-bin/rxpip_server.rexx?action=PING"
# STATUS: OK
# SERVER: RXPIP/1.0 (Regina ...)
```

Then a full publish/download round trip:

```bash
tar czf /tmp/test-1.0.0.rxpkg -C /tmp/some/dir test.rexx
curl -s -X POST \
  -H "X-Rxpip-Name: test" -H "X-Rxpip-Version: 1.0.0" \
  -H "X-Rxpip-Token: some-secret" \
  --data-binary @/tmp/test-1.0.0.rxpkg \
  "https://www.rexxpository.org/cgi-bin/rxpip_server.rexx?action=PUBLISH"
# STATUS: OK ... MESSAGE: published

curl -s "https://www.rexxpository.org/cgi-bin/rxpip_server.rexx?action=INFO&name=test"
```

If `PUBLISH` reports success but nothing shows up under
`/var/www/rexxpository.org/repo`, re-check step 2 — this is almost
always a permissions issue, not a protocol issue (see the callout above).

## 6. Header forwarding

`PUBLISH` metadata (name/version/author/summary/requires/kind/platform/
token) is read from `X-Rxpip-*` request headers, which Apache/mod_cgi
forwards as `HTTP_X_RXPIP_*` environment variables per the CGI spec —
this is standard Apache behavior and needs no special configuration. As
a defense against any intermediary (a reverse proxy, a CDN, a minimal
CGI handler in some other test setup) that might *not* forward custom
headers, the server also accepts the same fields as query-string
parameters, with headers taking precedence when both are present. You
don't need to do anything for this; it's automatic.

## 7. Backups

Everything the server owns is plain files under `repo/`:

```
repo/<name>/<version>/PACKAGE.META
repo/<name>/<version>/ARTIFACTS.META
repo/<name>/<version>/artifacts/<KIND>-<PLATFORM>.rxpkg
repo/.auth/<name>.owner
```

A regular `tar`/`rsync` of the `repo/` directory is a complete, restorable
backup — no database involved.

## 8. Testing the server on Windows

Production deployment targets Linux/Apache (above), but Regina testing
for this project happens on a Windows Server host. Here's how to stand
up the same kind of local test loop there that was used to verify the
Linux implementation.

### Prerequisites

- **Regina for Windows** — builds are available from the Regina project
  (regina-rexx.sourceforge.net); confirm `regina.exe` is on `PATH` and
  that `regina -a` is accepted (`-a`/`--args` is what makes each
  command-line argument arrive as its own `ARG(n)` element instead of
  being joined into one string — required for `rxpip.rexx` to parse
  multi-word values like `--summary="..."` correctly; see
  ARCHITECTURE.md §5).
- **`tar.exe` and `curl.exe` on `PATH`.** Windows Server 2019+ ships
  both in `System32` by default — check with `tar --version` and `curl
  --version` in a fresh shell. If either is missing (older Windows
  Server, or a stripped-down image), install Git for Windows, which
  bundles compatible versions of both, and put its `bin` (or
  `usr\bin`) directory on `PATH`.
- **Python 3**, only for the local CGI test harness below (not needed
  for production — Apache handles this role there).

### A local test loop (mirrors what was used on Linux)

Python's built-in CGI-capable HTTP server works the same way on
Windows and gives a real end-to-end HTTP test without installing IIS:

```powershell
$env:RXPIP_REPO_ROOT = "C:\rxpip-test\repo"
mkdir $env:RXPIP_REPO_ROOT -Force
mkdir "C:\rxpip-test\cgi-bin" -Force
copy server\rxpip_server.rexx "C:\rxpip-test\cgi-bin\"
cd C:\rxpip-test
python -m http.server 8089 --cgi
```

Then, from another shell:

```powershell
curl.exe -s "http://localhost:8089/cgi-bin/rxpip_server.rexx?action=PING"
```

If Python's CGI handler doesn't invoke `.rexx` files as CGI scripts
directly on your setup (it generally relies on an executable/shebang
convention that doesn't translate cleanly to Windows), the simplest
workaround is a thin wrapper the handler *can* execute — a
`rxpip_server.cmd` in the same `cgi-bin` directory:

```bat
@echo off
regina "%~dp0rxpip_server.rexx"
```

and point the test requests at `rxpip_server.cmd` instead. (This isn't
needed under real Apache/mod_cgi, which is configured to invoke
`.rexx` directly via `AddHandler cgi-script .rexx` — see §4.)

### Windows-specific things worth checking first

These are the parts of the Windows portability layer that could not be
executed anywhere in this project's own development (no Windows host
was available) — reasoned through carefully, but genuinely unverified.
Check them in roughly this order, since later ones build on earlier
ones working:

1. **`action=PING`** — no filesystem/shell involvement at all; if this
   fails, the problem is in CGI invocation itself (script not executing,
   wrong interpreter, etc.), not in anything RXPIP-specific.
2. **`action=PUBLISH`** on an empty repo — exercises `EnsureDir`
   (`mkdir`), the artifact/meta file writes, and `tar czf`/`tar tzf`
   reading back the file list. Confirm the artifact actually lands on
   disk under `repo\<name>\<version>\artifacts\`, not just that the
   HTTP response claims success (this exact class of "reports success,
   wrote nothing" failure mode bit the Linux test harness once too, for
   an unrelated permissions reason — see §5 in ARCHITECTURE.md).
3. **`action=LIST` / `action=ARTIFACTS` / `action=DOWNLOAD`** —
   exercises `dir /b` directory listing and the `if exist "path\"`
   directory test.
4. **Client `rxpip install`** — exercises the client's own `mkdir`,
   `tar xzf`, and `copy` calls into `%RXPIP_HOME%\lib`.
5. **Client `rxpip run`** — the most involved path: exercises
   `MergeScript`'s `TYPE`/`ECHO`/`&` sequence (confirm the merged
   temp file actually contains the original source, a bare `exit`
   line, and every installed package's source, in that order) and
   `RunInDir`'s `cd /d ... &&` invocation with the exit code correctly
   propagated back (`echo %ERRORLEVEL%` after a run that you know
   should fail is a quick way to check this).
6. **`rxpip run` with a multi-word argument** — confirms `ShellQuote`'s
   Windows branch actually survives the round trip; try something with
   an embedded space and, separately, an embedded double-quote.

If something in 2–6 doesn't work as described, the fix almost certainly
belongs in the one small platform-branch procedure responsible for that
operation (§6 of ARCHITECTURE.md lists which one), not scattered
elsewhere — that locality is the point of routing everything through
the portability layer in the first place.

## 9. Things to harden before wider/public use

The current auth model (first publish claims a package name with a
shared-secret token, stored as a plain file) is intentionally minimal —
enough to stop accidental or casual overwrites, not a real access-control
system. Before opening this up beyond trusted publishers, consider:

- Real per-user accounts/tokens instead of one flat shared secret per
  package
- Rate limiting on `PUBLISH` (nothing currently stops someone from
  hammering the endpoint)
- HTTPS-only enforcement (redirect or refuse plain HTTP)
- A size cap on uploaded artifacts (currently unbounded — `CONTENT_LENGTH`
  is trusted as given)
