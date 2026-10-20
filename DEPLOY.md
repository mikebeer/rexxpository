# Deploying the RXPIP server (AlmaLinux 9 on Hetzner)

Target: `www.rexxpository.org`, Apache (`httpd`) + CGI on AlmaLinux 9
(AlmaLinux 8 works the same way; paths and package names are identical).

> **Verification status.** The server code is covered by an end-to-end
> test suite (`tests/run_tests.sh`, 150+ checks over real HTTP against a
> CGI harness that behaves like Apache). The commands below for
> AlmaLinux itself (dnf, SELinux, firewalld, certbot) have **not** been
> executed on an AlmaLinux host from this project's development
> environment; they follow the standard procedure for that platform.
> The SELinux step in particular is where a first deployment most often
> needs a second look; §12 says how to diagnose it.

## 1. Packages

```bash
sudo dnf install -y epel-release
sudo dnf install -y httpd mod_ssl curl tar gzip coreutils regina-rexx
regina -v          # confirm it runs
```

If `regina-rexx` is not available for your release, build it from the
Regina source tarball (regina-rexx.sourceforge.net):

```bash
sudo dnf groupinstall -y "Development Tools"
tar xzf Regina-REXX-3.9.5.tar.gz && cd Regina-REXX-3.9.5
./configure && make && sudo make install     # installs /usr/local/bin/regina
```

If Regina ends up in `/usr/local/bin`, make sure the CGI sees it: either
symlink it to `/usr/bin/regina` or set `PATH` for Apache (`SetEnv PATH ...`
is not enough for the shebang; the symlink is simpler).

The server shells out to `tar`, `sha256sum`, `head`, `od`, `ls`, `mv`, `rm`
and `mkdir` (all in a stock install) and reads `/dev/urandom`. If
`sha256sum` or secure randomness were unavailable the server refuses to
create accounts rather than fall back to something weak.

## 2. Directory layout and ownership

Everything the server writes lives **outside** Apache's `DocumentRoot`,
so account data can never be served as a static file:

```bash
sudo mkdir -p /var/www/rexxpository/{cgi-bin,repo}
sudo chown -R apache:apache /var/www/rexxpository/repo
sudo chmod 750 /var/www/rexxpository/repo
sudo cp server/rxpip_server.rexx /var/www/rexxpository/cgi-bin/
sudo chmod 755 /var/www/rexxpository/cgi-bin/rxpip_server.rexx
```

The repo directory must be writable by the user Apache runs CGI as
(`apache` on AlmaLinux). Inside it the server creates package
directories, `.auth/` (users, token hashes, invites, owner lists) and
`.staging/` (uploads in flight); the dot-directories are never listed as
packages.

## 3. SELinux (leave it enforcing)

AlmaLinux ships with SELinux enforcing, and Apache is confined: it may
not execute scripts or write files except where labelled for it.

```bash
sudo dnf install -y policycoreutils-python-utils
sudo semanage fcontext -a -t httpd_sys_script_exec_t "/var/www/rexxpository/cgi-bin(/.*)?"
sudo semanage fcontext -a -t httpd_sys_rw_content_t  "/var/www/rexxpository/repo(/.*)?"
sudo restorecon -Rv /var/www/rexxpository
ls -dZ /var/www/rexxpository/cgi-bin /var/www/rexxpository/repo
```

You should see `httpd_sys_script_exec_t` and `httpd_sys_rw_content_t`.
Do not "fix" problems with `setenforce 0`; use the audit log (§12).

## 4. Apache virtual host

`/etc/httpd/conf.d/rexxpository.conf`:

```apache
<VirtualHost *:80>
    ServerName www.rexxpository.org
    # certbot will add the HTTPS vhost and this redirect; shown for clarity
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName www.rexxpository.org
    DocumentRoot /var/www/rexxpository/html

    ScriptAlias /cgi-bin/ /var/www/rexxpository/cgi-bin/
    <Directory "/var/www/rexxpository/cgi-bin">
        Options +ExecCGI
        AddHandler cgi-script .rexx
        Require all granted
    </Directory>

    # the web front page is the CGI's no-action page
    RedirectMatch 302 "^/$" "/cgi-bin/rxpip_server.rexx"

    SetEnv RXPIP_REPO_ROOT /var/www/rexxpository/repo
    # upload cap in bytes (default 5242880 = 5 MiB). Keep Apache's own limit
    # a little higher so the server can answer with its own clear error:
    SetEnv RXPIP_MAX_UPLOAD 5242880
    LimitRequestBody 5300000

    # TLS: managed by certbot (below). Tokens travel in request headers, so
    # this service must only be reachable over HTTPS.
</VirtualHost>
```

```bash
sudo mkdir -p /var/www/rexxpository/html     # empty DocumentRoot
sudo apachectl configtest && sudo systemctl enable --now httpd
```

`mod_cgid` is loaded by default on AlmaLinux (`conf.modules.d/01-cgi.conf`).
`mod_rewrite` is also loaded by default.

## 5. Firewall (two layers on Hetzner)

```bash
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
```

Hetzner Cloud also has its own **Cloud Firewall** in the Hetzner console,
independent of `firewalld`: allow inbound TCP 80 and 443 (and 22 from
your own address only). If the site works from the server itself but not
from outside, that is the first place to look.

## 6. HTTPS (Let's Encrypt)

Point the DNS A/AAAA records of `www.rexxpository.org` at the server first.

```bash
sudo dnf install -y certbot python3-certbot-apache
sudo certbot --apache -d www.rexxpository.org
sudo systemctl list-timers | grep certbot      # renewal is automatic
```

## 7. Smoke test

```bash
curl -s "https://www.rexxpository.org/cgi-bin/rxpip_server.rexx?action=PING"
# STATUS: OK
# SERVER: RXPIP/1.0 (Regina ...)
```

Open `https://www.rexxpository.org/` in a browser: the (empty) package
index should appear.

## 8. Accounts: how people get to publish

Accounts are **invite-only**: an open sign-up on a code repository is a
supply-chain risk, because every user who can publish is someone whose
code other people will run. There is no HTTP admin interface; the
operator manages accounts on the server, as the Apache user so file
ownership stays correct:

```bash
ADMIN='sudo -u apache env RXPIP_REPO_ROOT=/var/www/rexxpository/repo regina -a /var/www/rexxpository/cgi-bin/rxpip_server.rexx admin'

$ADMIN adduser mike          # your own account; prints the token ONCE
$ADMIN invite "for Anna"     # prints a single-use invite code ONCE
$ADMIN users
$ADMIN tokens mike
$ADMIN newtoken mike ci      # extra token (e.g. for CI)
$ADMIN revoke 1a2b3c4d       # revoke one token by id
$ADMIN lock anna             # revoke ALL of a user's tokens
$ADMIN owners mathutils
$ADMIN setowners mathutils mike anna     # recovery: replace owner list
```

A publisher then does, on their own machine:

```bash
rxpip config set REPO_URL https://www.rexxpository.org/cgi-bin/rxpip_server.rexx
rxpip register --user=anna --invite=inv_xxxxxxxx_xxxxxxxx...   # saves her token
rxpip publish mypkg.rxpkg --name=mypkg --version=1.0.0 --summary="..."
rxpip token new --label=laptop        # more tokens, self-service
rxpip owner add mypkg bob             # let another user publish
```

How it works:

- The **first publish of a name claims it**; the publisher becomes its
  owner. Any owner can add or remove other owners (never the last one).
- Tokens look like `rxp_<8 hex id>_<48 hex secret>` and are generated by
  the server. The server stores only a salted SHA-256 of each; a token
  cannot be recovered, only replaced. The client keeps its token in
  `~/.rxpip/credentials.txt` (mode 600).
- A token in the URL is refused (`TOKEN_IN_URL`): URLs end up in access
  logs. Tokens are accepted only in the `X-Rxpip-Token` header.
- Releases are immutable: re-publishing an existing version/kind/platform
  is a 409. Publish a new version instead.
- Uploads are capped (`RXPIP_MAX_UPLOAD`) and archives are validated
  (regular files only, flat safe names, at most 200 members).

### Web sign-up with moderation (optional)

Visitors can request an account at `?action=SIGNUP` (name, e-mail, location).
The server mails the administrator a review link; opening it shows the
request with **Approve** / **Reject** buttons. Approval mails the applicant a
single-use invite code, which they redeem with `rxpip register`. Pending
requests expire after 14 days (max. 100 pending, 3 per IP address).

Enable it in the virtual host (sign-up is off while `RXPIP_ADMIN_EMAIL` is unset):

```apache
    SetEnv RXPIP_ADMIN_EMAIL   you@example.org
    SetEnv RXPIP_PUBLIC_URL    https://www.rexxpository.org/cgi-bin/rxpip_server.rexx
    SetEnv RXPIP_MAIL_FROM     rxpip@rexxpository.org
```

It needs a working local MTA: `dnf install postfix && systemctl enable --now postfix`
(`/usr/sbin/sendmail`; set `RXPIP_SENDMAIL` to use another command that reads a
message on stdin). On SELinux add `setsebool -P httpd_can_sendmail 1`.
Set SPF/DKIM for the sender domain, or the mails land in spam.

### Private packages and a closed repository (optional)

A package published with `--private` (or switched with `rxpip visibility`) is
invisible to everyone except its owners and the users on its reader list:
`LIST`, `SEARCH`, `INFO`, `VERSIONS`, `ARTIFACTS`, `DOWNLOAD`, `OWNERS` and the
web pages answer exactly as for a package that does not exist. The clients send
their token with every read, so the same `rxpip install` works for people who
may see the package. The state lives in `repo/.auth/visibility/` and
`repo/.auth/readers/` (back it up with the rest of `.auth/`). A public package
cannot require a private one (publishing is refused with `PRIVATE_DEPENDENCY`).

To make the **whole repository** private, set (in both virtual-host files):

```apache
    SetEnv RXPIP_CLOSED 1
```

Every read then needs a valid token (HTTP 401 otherwise); only `PING`, the
sign-up form and `REGISTER` stay open, and the web pages show a short
"private repository" notice. Private packages inside a closed repository still
stay hidden from users who are not owners or readers. The browser views do
not send a token, so they list public packages only (or nothing, when closed).
Administrators can inspect or set visibility on the server with
`admin visibility <pkg> [public|private]`.

### Administrators, usage statistics and client releases

Make yourself an administrator (the user must exist):

```sh
sudo -u apache env RXPIP_REPO_ROOT=/var/www/rexxpository.org/repo \
    regina -a /var/www/rexxpository.org/cgi-bin/rxpip_server.rexx admin addadmin <user>
```

From then on `rxpip admin stats [--days=N]`, `rxpip admin users`,
`rxpip admin lock <user>` and `rxpip admin client-publish <kind> --version=V
[--min=V] <file>...` work with that user's token from any computer (the same
`stats [days]`, `admins`, `rmadmin <user>` exist as local admin commands). The
administrator list is `repo/.auth/admins`.

Every request is logged to `repo/.stats/<yyyymmdd>.log` (time, action, client
kind/version/OS, and a daily id that is a hash of address+day+secret salt; no
addresses, tokens or user names). Logs older than 400 days are deleted. They are
only readable by administrators (dot-directories are never served). Set
`SetEnv RXPIP_NOSTATS 1` in both virtual-host files to switch it off. The
directory must be writable by the web user, like the rest of `repo/`.

Client releases live in `repo/.clients/<kind>/<version>/` (kinds: `regina`,
`oorexx`, `netrexx`, `crexx`), with `LATEST` per kind. Publish a release from a
checkout, e.g. `rxpip admin client-publish regina --version=1.3.0 --min=1.0.0
client/rxpip.rexx` (and again with `oorexx`; `client/netrexx/Rxpip.nrx` for
`netrexx`, `client/crexx/rxpip.crexx` for `crexx`). The public action `CLIENT`
serves them, also in a closed repository. `tools/publish-clients.sh [--min=V]` does all four kinds at once (version taken from
each client's `ClientVersion`, launchers included); the releases are listed on the public
page `?action=DOWNLOADS` (linked as "get the client" on every page). Release files can carry a minisign signature: list `file` and `file.minisig` together in `client-publish`; the page then links the signature and shows the key (default: the project key, overridable with `RXPIP_MINISIGN_KEY`). Remember to raise `ClientVersion` in
the client source before releasing. Back up `.stats/` and `.clients/` with the rest of `repo/`.

## 9. Header forwarding

`PUBLISH` metadata and the token are read from `X-Rxpip-*` request
headers, which Apache forwards to CGI scripts as `HTTP_X_RXPIP_*`
environment variables per the CGI spec; no configuration is needed. If
you ever put a reverse proxy or CDN in front, make sure it forwards
`X-Rxpip-*` headers. For the **non-secret** metadata only, the server
also accepts query-string parameters as a fallback; the token never has a
fallback.

## 10. Backups

Everything is plain files under `repo/`, including account data:

```
repo/<name>/<version>/PACKAGE.META
repo/<name>/<version>/ARTIFACTS.META
repo/<name>/<version>/artifacts/<KIND>-<PLATFORM>.rxpkg
repo/.auth/users/<user>.user
repo/.auth/tokens/<id>.tok           (salted hashes, not tokens)
repo/.auth/invites/<id>.inv[.used]
repo/.auth/owners/<package>.owners
repo/.staging/                       (transient; safe to exclude)
```

```bash
sudo tar czf /root/rexxpository-$(date +%F).tgz --exclude=repo/.staging -C /var/www/rexxpository repo
```

Keep the backup readable by root only: it contains the token hashes. No
database is involved, so a restore is just unpacking into `repo/`
followed by `restorecon -R`.

## 11. Testing the server on Windows

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

7. **Account and security helpers** (new, all unverified on Windows):
   `Sha256Hex` and `RandomHex` use PowerShell (`SHA256`/`RandomNumberGenerator`)
   instead of `sha256sum` and `/dev/urandom`; run `rxpip_server.rexx admin
   adduser test` and confirm it prints a token and that
   `repo\.auth\tokens\*.tok` contains a `sha256$<32 hex>$<64 hex>` line.
   `WriteNew` (atomic create) is only check-then-write on Windows, and
   invite redemption uses `move` — fine for a test box, but concurrent
   first-publish and concurrent invite redemption are **not** race-safe
   there, which is one more reason production runs on Linux.
   On the client, `credentials.txt` cannot be chmod 600 on Windows; it
   relies on the permissions of your user profile.

If something in 2–7 doesn't work as described, the fix almost certainly
belongs in the one small platform-branch procedure responsible for that
operation (§6 of ARCHITECTURE.md lists which one), not scattered
elsewhere — that locality is the point of routing everything through
the portability layer in the first place.

## 12. Troubleshooting on AlmaLinux

| Symptom | Likely cause and check |
| --- | --- |
| HTTP 500 and `(13)Permission denied` in `/var/log/httpd/error_log` | SELinux label or file mode on `cgi-bin`; re-run §3, then `ls -Z` |
| PING works, PUBLISH says OK but nothing is written | `repo` not writable by `apache`, or not labelled `httpd_sys_rw_content_t` |
| `sudo ausearch -m avc -ts recent` shows `httpd_sys_script_t` denials | read the denial; fix the label (don't disable SELinux); `sudo audit2why` explains it |
| `Premature end of script headers` | Regina not found by the CGI (`which regina`, see §1), or a syntax error: run `sudo -u apache env GATEWAY_INTERFACE=CGI/1.1 REQUEST_METHOD=GET QUERY_STRING=action=PING regina /var/www/rexxpository/cgi-bin/rxpip_server.rexx` |
| `SERVER_NO_HASH` / `SERVER_NO_RANDOM` | `sha256sum` or `/dev/urandom` unavailable to the confined CGI; check `audit.log` |
| Works from the server, not from outside | `firewalld` (§5) or the Hetzner Cloud Firewall |
| Upload of a large package fails with HTTP 413 | over `RXPIP_MAX_UPLOAD` (server) or `LimitRequestBody` (Apache) |

## 13. Not done yet (known gaps)

- **Rate limiting.** Nothing throttles requests. Invite codes and tokens
  carry 128/192 bits of randomness, so guessing is not a practical
  attack, but a flood of requests is still possible; put `fail2ban` or
  an Apache/edge rate limit in front for public use.
- **No password or e-mail flow.** Lost tokens are replaced by the
  operator (`newtoken`); there is no self-service recovery by design.
- **No package deletion or yank** over HTTP: remove files on the server
  by hand if you must (releases are meant to be immutable).
- **Name policy.** First come, first served; there is no
  typosquatting protection or reserved-name list.
- **Concurrent owner-list edits** (two owners changing the same
  package's owner list in the same instant) are last-writer-wins.
- Windows server paths (PowerShell hashing and randomness, non-atomic
  claims) are untested; see §11.

