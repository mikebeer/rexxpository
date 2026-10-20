#!/usr/bin/regina
/* ---------------------------------------------------------------------
   RXPIP SERVER  --  Regina REXX implementation
   ---------------------------------------------------------------------
   CGI endpoint for the RXPIP package repository (www.rexxpository.org).
   Deploy as /usr/lib/cgi-bin/rxpip_server.rexx under Apache mod_cgi
   (see docs/DEPLOY.md).

   Protocol: simple RFC822-style "stanza" text responses (easy to PARSE
   in REXX -- no JSON library required on either end). Binary package
   archives are streamed raw for the DOWNLOAD action.

   Design note: all helper routines communicate via plain strings
   (RETURN values), never via cross-procedure stem exposure. Classic
   REXX only shares a stem between procedures that are directly
   nested in the same EXPOSE chain, which makes "write into caller's
   stem" helpers fragile and non-portable across interpreters. Using
   delimited strings ('01'x-separated internally) keeps every routine
   self-contained and behaves identically on Regina, cREXX, ooRexx and
   NetRexx (classic mode).

   Actions (via QUERY_STRING):
     (no action)       HTML package index with search      (?q=<term>)
     action=PKG       &name=<pkg> [&version=<ver>]  HTML package page
     action=PING
     action=LIST
     action=SEARCH   &q=<term>
     action=INFO      &name=<pkg>            [&version=<ver>]
     action=VERSIONS  &name=<pkg>
     action=ARTIFACTS &name=<pkg>            [&version=<ver>]
     action=DOWNLOAD  &name=<pkg>            [&version=<ver>]
                       [&kind=<SOURCE|BYTECODE>] [&platform=<tag>]
     action=OWNERS    &name=<pkg>            -> OWNERS: user user ...
     -- the following are POST + X-Rxpip-Token header (a user token) --
     action=REGISTER  X-Rxpip-Invite, X-Rxpip-User   (invite-only sign-up;
                       returns the first token, shown once; no token needed)
     action=WHOAMI | TOKENS | NEWTOKEN [X-Rxpip-Label] | REVOKE [X-Rxpip-Token-Id]
     action=ADDOWNER | REMOVEOWNER   X-Rxpip-Name, X-Rxpip-User
     action=PUBLISH   (POST body = raw artifact bytes; metadata via headers
                       X-Rxpip-Name, X-Rxpip-Version, X-Rxpip-Author,
                       X-Rxpip-Summary, X-Rxpip-Requires, X-Rxpip-Kind,
                       X-Rxpip-Platform, X-Rxpip-Token -- or the same as
                       query-string params, which are used as a fallback)

   ARTIFACT MODEL -- one server, many REXX runtimes:
   Rather than reimplementing this server once per REXX interpreter, a
   single package VERSION can carry several interchangeable ARTIFACTS,
   each tagged with:
     KIND:     SOURCE   -- portable classic-REXX source (.rexx files in
                            a tarball). Works with any interpreter that
                            can run RXPIP's source-concatenation build
                            (see client). This is the default and the
                            common case.
               BYTECODE -- a precompiled artifact for one specific
                            interpreter/OS/architecture (e.g. a cREXX
                            .rxbin image). Opt-in, published alongside
                            (not instead of) a SOURCE artifact.
     PLATFORM: 'any' for SOURCE artifacts, or a specific tag such as
               'crexx-linux-x86_64' for BYTECODE artifacts.
   A publisher can ship just a SOURCE/any artifact (the default -- this
   is all that's needed for REGINA, cREXX-in-a-future-Classic-mode,
   ooRexx, NetRexx classic scripts, etc.) and, later, additional
   BYTECODE artifacts for whichever specific runtimes benefit from a
   precompiled form. The client resolves the best match for its own
   platform, falling back to SOURCE/any when no exact BYTECODE match
   exists. This keeps the SERVER implementation singular (Regina, as
   tested here) while the ECOSYSTEM stays multi-runtime through data,
   not code.
   --------------------------------------------------------------------- */

signal on syntax name Bomb
signal on novalue name Bomb

/* ----- configuration -------------------------------------------------- */
REPO_ROOT = value('RXPIP_REPO_ROOT',,'ENVIRONMENT')
if REPO_ROOT = '' then REPO_ROOT = '/var/www/rexxpository.org/repo'
AUTH_DIR  = REPO_ROOT || '/.auth'
MAX_UPLOAD = value('RXPIP_MAX_UPLOAD',,'ENVIRONMENT')
if \datatype(MAX_UPLOAD, 'W') then MAX_UPLOAD = 5242880
if MAX_UPLOAD < 1 then MAX_UPLOAD = 5242880

/* ----- command-line admin mode (never reachable through CGI) ----------- */
if value('GATEWAY_INTERFACE',,'ENVIRONMENT') = '' then do
  call AdminMain AUTH_DIR, CliArgs(arg(1), arg(2), arg(3), arg(4), arg(5), arg(6), arg(7))
  exit 0
end

/* ----- read CGI environment -------------------------------------------*/
method_   = value('REQUEST_METHOD',,'ENVIRONMENT')
qstring   = value('QUERY_STRING',,'ENVIRONMENT')
clen      = value('CONTENT_LENGTH',,'ENVIRONMENT')
if clen = '' then clen = 0

action = translate(QGet(qstring, 'ACTION'))
if action \= 'PING' & action \= 'DOWNLOADS' & action \= '' & action \= 'HOME' & action \= 'PKG' & action \= 'SIGNUP' & action \= 'REVIEW' then call LogEvent REPO_ROOT || '/.stats', 'REQ', lower(action)

select
  when action = '' | action = 'HOME' then call Web_Home REPO_ROOT, AUTH_DIR, qstring
  when action = 'PKG'      then call Web_Package REPO_ROOT, AUTH_DIR, qstring
  when action = 'DOWNLOADS' then call Web_Downloads REPO_ROOT, qstring
  when action = 'SIGNUP'   then call Web_Signup AUTH_DIR, method_, clen
  when action = 'REVIEW'   then call Web_Review AUTH_DIR, method_, clen, qstring
  when action = 'PING'     then call Action_Ping
  when action = 'LIST'     then call Action_List     REPO_ROOT, AUTH_DIR
  when action = 'SEARCH'   then call Action_Search    REPO_ROOT, AUTH_DIR, qstring
  when action = 'INFO'     then call Action_Info      REPO_ROOT, AUTH_DIR, qstring
  when action = 'VERSIONS' then call Action_Versions  REPO_ROOT, AUTH_DIR, qstring
  when action = 'ARTIFACTS' then call Action_Artifacts REPO_ROOT, AUTH_DIR, qstring
  when action = 'DOWNLOAD' then call Action_Download  REPO_ROOT, AUTH_DIR, qstring
  when action = 'VISIBILITY' then call Action_Visibility AUTH_DIR, method_
  when action = 'READERS' | action = 'ADDREADER' | action = 'REMOVEREADER' then call Action_Readers AUTH_DIR, method_, action
  when action = 'REGISTER' then call Action_Register  AUTH_DIR, method_
  when action = 'WHOAMI'   then call Action_Whoami    AUTH_DIR, method_
  when action = 'NEWTOKEN' then call Action_NewToken  AUTH_DIR, method_
  when action = 'TOKENS'   then call Action_Tokens    AUTH_DIR, method_
  when action = 'REVOKE'   then call Action_Revoke    AUTH_DIR, method_
  when action = 'OWNERS'   then call Action_Owners    AUTH_DIR, qstring
  when action = 'ADDOWNER' then call Action_ChangeOwner AUTH_DIR, method_, 'ADD'
  when action = 'REMOVEOWNER' then call Action_ChangeOwner AUTH_DIR, method_, 'REMOVE'
  when action = 'CLIENT'   then call Action_Client    REPO_ROOT, qstring
  when action = 'ADMINCLIENT' then call Action_AdminClient REPO_ROOT, AUTH_DIR, method_, clen, MAX_UPLOAD
  when action = 'ADMINSTATS' then call Action_AdminStats REPO_ROOT, AUTH_DIR, method_
  when action = 'ADMINUSERS' then call Action_AdminUsers AUTH_DIR, method_
  when action = 'ADMINLOCK'  then call Action_AdminLock  AUTH_DIR, method_
  when action = 'PUBLISH'  then call Action_Publish   REPO_ROOT, AUTH_DIR, method_, clen, MAX_UPLOAD
  otherwise do
    call TextHeader
    call ErrorBody 'UNKNOWN_ACTION', "no such action"
  end
end

exit 0

/* =======================================================================
   ACTIONS
   ======================================================================= */

Action_Ping: procedure
  call TextHeader
  say 'STATUS: OK'
  say 'SERVER: RXPIP/1.0 (Regina ' || RexxVersionShort() || ')'
  return

Action_List:
  parse arg root, authdir
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  call TextHeader
  names = VisibleNames(root, authdir, viewer)
  n = words(names)
  say 'STATUS: OK'
  say 'COUNT:' n
  say ''
  do i = 1 to n
    nm = word(names, i)
    ver = LatestVersionOf(root, nm)
    if ver = '' then iterate
    call EmitStanza MetaStr(root, nm, ver)
  end
  return

Action_Search:
  parse arg root, authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  call TextHeader
  term = translate(QGet(qstring, 'Q'))
  names = VisibleNames(root, authdir, viewer)
  n = words(names)
  say 'STATUS: OK'
  hitlist = ''
  hitcount = 0
  do i = 1 to n
    nm = word(names, i)
    ver = LatestVersionOf(root, nm)
    if ver = '' then iterate
    ms = MetaStr(root, nm, ver)
    parse var ms f1 '01'x f2 '01'x f3 '01'x f4 '01'x f5
    hay = translate(f1) f4
    if term = '' | pos(term, translate(hay)) > 0 then do
      hitlist = hitlist || nm || ' '
      hitcount = hitcount + 1
    end
  end
  say 'COUNT:' hitcount
  say ''
  do i = 1 to words(hitlist)
    nm = word(hitlist, i)
    ver = LatestVersionOf(root, nm)
    call EmitStanza MetaStr(root, nm, ver)
  end
  return

Action_Info:
  parse arg root, authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  call TextHeader
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call ErrorBody 'BAD_NAME', 'invalid package name'
    return
  end
  ver = QGet(qstring, 'VERSION')
  if ver \= '' & \IsSafeVersion(ver) then do
    call ErrorBody 'BAD_VERSION', 'invalid version'
    return
  end
  if ver = '' then ver = LatestVersionOf(root, name)
  if ver = '' | \FileExists(MetaPath(root,name,ver)) | \CanRead(authdir, viewer, name) then do
    call ErrorBody 'NOT_FOUND', "package '" || name || "' not found"
    return
  end
  say 'STATUS: OK'
  say 'COUNT: 1'
  if IsPrivate(authdir, name) then say 'VISIBILITY: private'
  say ''
  call EmitStanza MetaStr(root, name, ver)
  return

Action_Versions:
  parse arg root, authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  call TextHeader
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call ErrorBody 'BAD_NAME', 'invalid package name'
    return
  end
  vs = VersionsStr(root, name)
  if \CanRead(authdir, viewer, name) then vs = ''
  say 'STATUS: OK'
  say 'COUNT:' words(vs)
  say ''
  do i = 1 to words(vs)
    say 'VERSION:' word(vs, i)
  end
  return

Action_Artifacts:
  parse arg root, authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  call TextHeader
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call ErrorBody 'BAD_NAME', 'invalid package name'
    return
  end
  ver = QGet(qstring, 'VERSION')
  if ver \= '' & \IsSafeVersion(ver) then do
    call ErrorBody 'BAD_VERSION', 'invalid version'
    return
  end
  if ver = '' then ver = LatestVersionOf(root, name)
  if ver = '' | \CanRead(authdir, viewer, name) then do
    call ErrorBody 'NOT_FOUND', "package '" || name || "' not found"
    return
  end
  recs = ArtifactsStr(root, name, ver)
  n = 0
  rest = recs
  do while rest \= ''
    parse var rest one '0a'x rest
    if one \= '' then n = n + 1
  end
  say 'STATUS: OK'
  say 'COUNT:' n
  say ''
  rest = recs
  do while rest \= ''
    parse var rest one '0a'x rest
    if one = '' then iterate
    parse var one k '01'x p '01'x f
    say 'KIND:' k
    say 'PLATFORM:' p
    say 'FILES:' f
    say ''
  end
  return

Action_Download:
  parse arg root, authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid package name'
    return
  end
  ver = QGet(qstring, 'VERSION')
  if ver \= '' & \IsSafeVersion(ver) then do
    call Fail 400, 'BAD_VERSION', 'invalid version'
    return
  end
  if ver = '' then ver = LatestVersionOf(root, name)
  kind = QGet(qstring, 'KIND')
  if kind = '' then kind = 'SOURCE'
  platform = QGet(qstring, 'PLATFORM')
  if platform = '' then platform = 'any'
  if \IsSafeKind(kind) | \IsSafeToken(platform) then do
    call Fail 400, 'BAD_ARTIFACT', 'invalid kind/platform'
    return
  end
  artfile = ArtifactPath(root, name, ver, kind, platform)
  if ver = '' | \FileExists(artfile) | \CanRead(authdir, viewer, name) then do
    call Fail 404, 'NOT_FOUND', "no " || kind || "/" || platform || " artifact for '" || name || "' " || ver
    return
  end
  call LogEvent root || '/.stats', 'DL', name, ver, kind || '/' || platform
  sz = stream(artfile, 'c', 'query size')
  say 'Content-Type: application/octet-stream'
  say 'Content-Disposition: attachment; filename="' || name || '-' || ver || '-' || kind || '-' || platform || '.rxpkg"'
  say 'Content-Length:' sz
  say ''
  data = charin(artfile, 1, sz)
  call stream artfile, 'c', 'close'
  call charout , data
  return

/* PUBLISH -- hardened:
   - the secret token is accepted ONLY in the X-Rxpip-Token header; a
     token in the URL is refused outright (URLs land in access logs)
   - tokens are stored as sha256$<salt>$<hash>, never in the clear
   - uploads are size-capped (RXPIP_MAX_UPLOAD, default 5 MiB) before any
     of the body is read
   - metadata values are checked for control characters (a newline in a
     summary would otherwise inject fake fields into PACKAGE.META)
   - the archive is validated: regular files only, flat safe names
   - releases are immutable: an existing artifact is never overwritten
   - the body is staged, validated, then moved into place, and the name
     is only claimed once the upload has proven good */
Action_Publish:
  parse arg root, authdir, method_, clen, maxup
  if translate(method_) \= 'POST' then do
    call Fail 405, 'METHOD_NOT_ALLOWED', 'publish requires POST'
    return
  end
  qstring = value('QUERY_STRING',,'ENVIRONMENT')
  if QGet(qstring, 'TOKEN') \= '' then do
    call Fail 400, 'TOKEN_IN_URL', 'send the token only in the X-Rxpip-Token header, never in the URL (URLs are logged)'
    return
  end
  /* Non-secret metadata normally arrives as X-Rxpip-* headers (Apache
     forwards them as HTTP_X_RXPIP_*); the query string is accepted as a
     fallback for handlers that don't forward custom headers. */
  name     = HdrOrQuery('HTTP_X_RXPIP_NAME', qstring, 'NAME')
  ver      = HdrOrQuery('HTTP_X_RXPIP_VERSION', qstring, 'VERSION')
  author   = HdrOrQuery('HTTP_X_RXPIP_AUTHOR', qstring, 'AUTHOR')
  summary  = HdrOrQuery('HTTP_X_RXPIP_SUMMARY', qstring, 'SUMMARY')
  requires = HdrOrQuery('HTTP_X_RXPIP_REQUIRES', qstring, 'REQUIRES')
  kind     = HdrOrQuery('HTTP_X_RXPIP_KIND', qstring, 'KIND')
  if kind = '' then kind = 'SOURCE'
  kind     = translate(strip(kind))
  platform = HdrOrQuery('HTTP_X_RXPIP_PLATFORM', qstring, 'PLATFORM')
  if platform = '' then platform = 'any'
  vis      = lower(strip(HdrOrQuery('HTTP_X_RXPIP_VISIBILITY', qstring, 'VISIBILITY')))
  token    = value('HTTP_X_RXPIP_TOKEN',,'ENVIRONMENT')

  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid or missing package name'
    return
  end
  if \IsSafeVersion(ver) then do
    call Fail 400, 'BAD_VERSION', 'invalid/missing version (expected dotted numeric, e.g. 1.2.0)'
    return
  end
  if \IsSafeKind(kind) then do
    call Fail 400, 'BAD_KIND', 'kind must be SOURCE or BYTECODE'
    return
  end
  if \IsSafeToken(platform) then do
    call Fail 400, 'BAD_PLATFORM', 'invalid platform tag'
    return
  end
  if \IsSafeMeta(author, 100) | \IsSafeMeta(summary, 200) then do
    call Fail 400, 'BAD_METADATA', 'author (max 100) and summary (max 200) must be plain text without control characters'
    return
  end
  if \IsSafeRequires(requires) then do
    call Fail 400, 'BAD_REQUIRES', 'requires must be space/comma separated "name" or "name>=version" entries'
    return
  end
  if vis \= '' & vis \= 'public' & vis \= 'private' then do
    call Fail 400, 'BAD_VISIBILITY', 'visibility must be public or private'
    return
  end
  if token = '' then do
    call Fail 401, 'NO_TOKEN', 'publish requires the X-Rxpip-Token header'
    return
  end
  if \IsSafeSecret(token) then do
    call Fail 401, 'BAD_TOKEN', 'token must be 16-128 characters from A-Z a-z 0-9 . _ ~ -'
    return
  end
  if \datatype(clen, 'W') then clen = 0
  if clen < 1 then do
    call Fail 400, 'EMPTY_BODY', 'no package data received'
    return
  end
  if clen > maxup then do
    call Fail 413, 'TOO_LARGE', 'artifact exceeds the ' || maxup || ' byte upload limit'
    return
  end
  if Sha256Hex('rxpip') = '' then do
    call Fail 500, 'SERVER_NO_HASH', 'server has no SHA-256 tool (sha256sum, shasum or PowerShell)'
    return
  end

  user = AuthUser(authdir, token)
  if user = '' then do
    call Fail 401, 'BAD_TOKEN', 'unknown or revoked token (create an account with an invite: rxpip register)'
    return
  end
  call EnsureDir authdir || '/owners'
  ownersfile = authdir || '/owners/' || name || '.owners'
  claiming = 0
  if FileExists(ownersfile) then do
    if \IsOwner(authdir, name, user) then do
      call Fail 403, 'FORBIDDEN', "'" || user || "' is not an owner of '" || name || "'"
      return
    end
  end
  else claiming = 1

  /* a public package must not depend on a private one: anonymous users
     could not install it. (Not checked in a closed repository, where
     every read needs a token anyway.) */
  finalvis = vis
  if finalvis = '' then do
    finalvis = 'public'
    if IsPrivate(authdir, name) then finalvis = 'private'
  end
  if finalvis = 'public' & \IsClosed() then do
    rq = translate(requires, ' ', ',')
    do i = 1 to words(rq)
      parse value word(rq, i) with rn '>=' .
      if IsSafeToken(rn) then do
        if IsPrivate(authdir, rn) then do
          call Fail 409, 'PRIVATE_DEPENDENCY', "a public package cannot require the private package '" || rn || "' - publish with visibility private, or make '" || rn || "' public"
          return
        end
      end
    end
  end

  artfile = ArtifactPath(root, name, ver, kind, platform)
  if FileExists(artfile) then do
    call Fail 409, 'ALREADY_EXISTS', kind || '/' || platform || ' artifact for ' || name || ' ' || ver || ' already exists; releases are immutable - publish a new version'
    return
  end

  /* stage inside the repo (same filesystem, so the final move is an atomic
     rename) but outside any package directory, so a rejected upload leaves
     no trace; dot-directories are never listed as packages */
  stagedir = root || '/.staging'
  call EnsureDir stagedir
  stage = stagedir || '/upload_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  data = charin(, , clen)
  if length(data) \= clen then do
    call Fail 400, 'SHORT_BODY', 'received fewer bytes than Content-Length announced'
    return
  end
  call charout stage, data
  call stream stage, 'c', 'close'
  data = ''

  v = ValidateArchive(stage)
  parse var v vstat '01'x vrest
  if vstat \= 'OK' then do
    call DelFile stage
    call Fail 400, 'BAD_ARCHIVE', vrest
    return
  end
  filelist = vrest

  if claiming then do
    if \WriteNew(ownersfile, user || '0a'x) then do
      /* lost a race with a concurrent first publish of the same name */
      if \IsOwner(authdir, name, user) then do
        call DelFile stage
        call Fail 403, 'FORBIDDEN', "'" || name || "' was claimed by someone else just now"
        return
      end
    end
  end

  /* set visibility BEFORE the artifact appears, so a private package is
     never readable even for a moment */
  if claiming | vis \= '' then call SetVisibility authdir, name, finalvis
  call EnsureDir root || '/' || name || '/' || ver || '/artifacts'
  call MoveFile stage, artfile
  call WriteArtifactRecord root, name, ver, kind, platform, filelist
  note = WriteMetaIfAbsent(root, name, ver, author, summary, requires)
  call LogEvent root || '/.stats', 'PUB', name, ver, kind || '/' || platform

  call TextHeader
  say 'STATUS: OK'
  say 'NAME:' name
  say 'VERSION:' ver
  say 'KIND:' kind
  say 'PLATFORM:' platform
  if note \= '' then say 'NOTE:' note
  say 'MESSAGE: published'
  return

/* =======================================================================
   HELPERS  (all self-contained -- return plain strings, no shared stems)
   ======================================================================= */

/* an HTTP error: Status header + plain-text STATUS/CODE/MESSAGE body */
Fail: procedure
  parse arg http, code, msg
  select
    when http = 400 then reason = 'Bad Request'
    when http = 401 then reason = 'Unauthorized'
    when http = 403 then reason = 'Forbidden'
    when http = 404 then reason = 'Not Found'
    when http = 405 then reason = 'Method Not Allowed'
    when http = 409 then reason = 'Conflict'
    when http = 413 then reason = 'Payload Too Large'
    otherwise reason = 'Internal Server Error'
  end
  say 'Status:' http reason
  say 'Content-Type: text/plain; charset=utf-8'
  say ''
  say 'STATUS: ERROR'
  say 'CODE:' code
  say 'MESSAGE:' msg
  return

/* request header (CGI env var) with query-string fallback; NOT for secrets */
HdrOrQuery: procedure
  parse arg envname, qs, key
  v = value(envname,,'ENVIRONMENT')
  if v = '' then v = QGet(qs, key)
  return v

/* secrets: 16-128 chars of A-Z a-z 0-9 . _ ~ -  (also keeps shell-safe) */
IsSafeSecret: procedure
  parse arg t
  if length(t) < 16 | length(t) > 128 then return 0
  return verify(t, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-') = 0

/* free-text metadata: length-capped, no control characters (CR/LF/NUL
   etc. would let a value break out of its line in the META files) */
IsSafeMeta: procedure
  parse arg s, maxlen
  if length(s) > maxlen then return 0
  ctl = xrange('00'x, '1f'x) || '7f'x
  return verify(s, ctl, 'M') = 0

/* "name" or "name>=version" entries separated by blanks and/or commas */
IsSafeRequires: procedure
  parse arg r
  if \IsSafeMeta(r, 500) then return 0
  r = translate(r, ' ', ',')
  do i = 1 to words(r)
    w = word(r, i)
    n = w
    v = ''
    if pos('>=', w) > 0 then parse var w n '>=' v
    if \IsSafeToken(n) then return 0
    if pos('>=', w) > 0 & \IsSafeVersion(v) then return 0
  end
  return 1

/* a member name inside an uploaded archive: flat, no leading dot */
IsSafeFileName: procedure
  parse arg n
  if n = '' | length(n) > 100 then return 0
  if left(n,1) = '.' then return 0
  return verify(n, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-') = 0

/* ---- crypto helpers -------------------------------------------------
   Secrets travel to child processes through an environment variable, never
   on a command line (visible in `ps`) and never via a temp file. Failure
   is reported as '' and callers must fail closed -- in particular
   RandomHex never falls back to a weak PRNG. */

IsHex: procedure
  parse arg h, n
  return length(h) = n & datatype(h, 'X')

Lower: procedure
  parse arg s
  return translate(s, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')

/* SHA-256 of a string as 64 lowercase hex chars, or '' if no tool works */
Sha256Hex: procedure
  parse arg s
  call value 'RXPIP_HASH_IN', s, 'ENVIRONMENT'
  first = ''
  if IsWindows() then do
    address system 'powershell -NoProfile -NonInteractive -Command "$b=[Text.Encoding]::UTF8.GetBytes($env:RXPIP_HASH_IN);([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace ''-'','''').ToLower()"' with output stem o.
    if o.0 >= 1 then first = word(o.1, 1)
  end
  else do
    address system 'printf %s "$RXPIP_HASH_IN" | sha256sum 2>/dev/null' with output stem o.
    if o.0 >= 1 then first = word(o.1, 1)
    if \IsHex(first, 64) then do
      /* macOS and BSD ship shasum rather than sha256sum */
      address system 'printf %s "$RXPIP_HASH_IN" | shasum -a 256 2>/dev/null' with output stem o.
      first = ''
      if o.0 >= 1 then first = word(o.1, 1)
    end
  end
  call value 'RXPIP_HASH_IN', '', 'ENVIRONMENT'
  if \IsHex(first, 64) then return ''
  return Lower(first)

/* n cryptographically random bytes as 2n hex chars, or '' on failure */
RandomHex: procedure
  parse arg n
  if IsWindows() then do
    address system 'powershell -NoProfile -NonInteractive -Command "$b=New-Object byte[] ' || n || ';[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b);(($b|ForEach-Object{$_.ToString(''x2'')}) -join '''')"' with output stem o.
  end
  else do
    address system 'head -c ' || n || ' /dev/urandom | od -An -tx1 | tr -d " \n"' with output stem o.
  end
  r = ''
  if o.0 >= 1 then r = word(o.1, 1)
  if \IsHex(r, 2 * n) then return ''
  return Lower(r)

/* "sha256$<salt>$<hash>" for a token, or '' if randomness is unavailable */
MakeSecretRecord: procedure
  parse arg token
  salt = RandomHex(16)
  if salt = '' then return ''
  h = Sha256Hex(salt || token)
  if h = '' then return ''
  return 'sha256$' || salt || '$' || h

/* does token match a stored "sha256$salt$hash" record? (0 on any doubt) */
VerifySecret: procedure
  parse arg token, rec
  parse var rec scheme '$' salt '$' h
  if scheme \= 'sha256' then return 0
  if \IsHex(salt, 32) | \IsHex(h, 64) then return 0
  calc = Sha256Hex(salt || token)
  return calc \= '' & calc = Lower(h)

/* create file with content only if it does not exist yet; 1 = created.
   Unix uses a noclobber redirect, which is atomic. Windows has no such
   shell primitive, so there it is check-then-write (small race window). */
WriteNew: procedure
  parse arg file, content
  if IsWindows() then do
    if FileExists(file) then return 0
    call charout file, content
    call stream file, 'c', 'close'
    return 1
  end
  call value 'RXPIP_NEW_CONTENT', content, 'ENVIRONMENT'
  address system '(set -C; printf %s "$RXPIP_NEW_CONTENT" > "' || file || '") 2>/dev/null'
  ok = (rc = 0)
  call value 'RXPIP_NEW_CONTENT', '', 'ENVIRONMENT'
  return ok

/* Validate an uploaded .rxpkg (gzip'd tar): at most 200 members, regular
   files only (no symlinks/hardlinks/devices), top-level only, safe names.
   Returns 'OK' '01'x 'space separated file list'  or  'ERR' '01'x 'why'. */
ValidateArchive: procedure
  parse arg f
  nul = NullSink()
  tn = TempDir() || '/rxpip_vn_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  tv = TempDir() || '/rxpip_vv_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  'tar tzf "' || f || '" 2>' || nul || ' >"' || tn || '"'
  'tar tvzf "' || f || '" 2>' || nul || ' >"' || tv || '"'
  nn = 0
  nv = 0
  if FileExists(tn) then do
    do while lines(tn) > 0
      nn = nn + 1
      nm.nn = linein(tn)
    end
    call stream tn, 'c', 'close'
  end
  if FileExists(tv) then do
    do while lines(tv) > 0
      nv = nv + 1
      vl.nv = linein(tv)
    end
    call stream tv, 'c', 'close'
  end
  call DelFile tn
  call DelFile tv
  if nn = 0 then return 'ERR' || '01'x || 'not a readable gzip-compressed tar archive, or it is empty'
  if nn \= nv then return 'ERR' || '01'x || 'archive listing is inconsistent (unusual member names?)'
  if nn > 200 then return 'ERR' || '01'x || 'archive has more than 200 members'
  files = ''
  do i = 1 to nn
    t = left(vl.i, 1)
    if t \= '-' & t \= 'd' then return 'ERR' || '01'x || 'archive contains a link or special file; only regular files are allowed'
    n = strip(nm.i)
    if left(n, 2) = './' then n = substr(n, 3)
    if right(n, 1) = '/' then n = left(n, length(n) - 1)
    if n = '' | n = '.' then iterate
    if t = 'd' then return 'ERR' || '01'x || 'archive contains a directory; files must be at the top level'
    if \IsSafeFileName(n) then return 'ERR' || '01'x || 'unsafe or nested file name in archive: ' || left(n, 40)
    files = files n
  end
  files = strip(files)
  if files = '' then return 'ERR' || '01'x || 'archive contains no files'
  return 'OK' || '01'x || files

/* PACKAGE.META describes a version and is written once, by its first
   artifact. Later artifacts of the same version (e.g. a BYTECODE one) must
   not rewrite it; returns a NOTE if their metadata differs. */
WriteMetaIfAbsent: procedure
  parse arg root, name, ver, author, summary, requires
  mf = MetaPath(root, name, ver)
  mine = name || '01'x || ver || '01'x || author || '01'x || summary || '01'x || requires
  if FileExists(mf) then do
    if MetaStr(root, name, ver) \= mine then return 'metadata for this version was already set by its first artifact and was left unchanged'
    return ''
  end
  call charout mf, 'NAME:' name || '0a'x
  call charout mf, 'VERSION:' ver || '0a'x
  call charout mf, 'AUTHOR:' author || '0a'x
  call charout mf, 'SUMMARY:' summary || '0a'x
  call charout mf, 'REQUIRES:' requires || '0a'x
  call stream mf, 'c', 'close'
  return ''


/* =======================================================================
   READ-ONLY WEB FRONTEND
   -----------------------------------------------------------------------
   Served by the same CGI script:   <script>            package index + search
                                    <script>?action=PKG&name=<pkg>[&version=<v>]
   Pure server-rendered HTML, no JavaScript, no cookies, no state. Every
   value that came from package metadata is HTML-escaped; a strict
   Content-Security-Policy forbids scripts and external loads anyway.
   ======================================================================= */

/* HTML-escape (no CHANGESTR: it is not available in every interpreter) */
Esc: procedure
  parse arg s
  out = ''
  do i = 1 to length(s)
    c = substr(s, i, 1)
    select
      when c = '&' then out = out || '&amp;'
      when c = '<' then out = out || '&lt;'
      when c = '>' then out = out || '&gt;'
      when c = '"' then out = out || '&quot;'
      when c = "'" then out = out || '&#39;'
      otherwise out = out || c
    end
  end
  return out

HtmlHeader: procedure
  parse arg http, title
  if http \= 200 then do
    if http = 404 then say 'Status: 404 Not Found'
    else if http = 400 then say 'Status: 400 Bad Request'
    else say 'Status:' http
  end
  say 'Content-Type: text/html; charset=utf-8'
  say "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'"
  say 'X-Content-Type-Options: nosniff'
  say 'Referrer-Policy: no-referrer'
  say ''
  say '<!doctype html>'
  say '<html lang="en"><head><meta charset="utf-8">'
  say '<meta name="viewport" content="width=device-width, initial-scale=1">'
  say '<title>' || Esc(title) || '</title>'
  say '<style>'
  say ':root{--bg:#fff;--fg:#1c1e21;--mute:#667;--line:#dde;--acc:#0b57d0;--code:#f3f4f7}'
  say '@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e6e8ea;--mute:#9aa;--line:#2c3036;--acc:#8ab4f8;--code:#20242a}}'
  say 'body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}'
  say 'main{max-width:60rem;margin:0 auto;padding:0 16px 3rem}'
  say 'header{border-bottom:1px solid var(--line);margin-bottom:1.5rem}'
  say 'header div{max-width:60rem;margin:0 auto;padding:1rem 16px}'
  say 'header a{color:var(--fg);font-weight:700;text-decoration:none;font-size:1.25rem}'
  say 'a{color:var(--acc)} h1{font-size:1.6rem;margin:.2em 0} h2{font-size:1.1rem;margin-top:2rem}'
  say 'table{border-collapse:collapse;width:100%} th,td{text-align:left;padding:.5rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}'
  say 'th{color:var(--mute);font-weight:600;font-size:.85rem}'
  say 'code,pre{background:var(--code);border-radius:6px;font-family:ui-monospace,monospace;font-size:.9rem}'
  say 'code{padding:.1em .4em} pre{padding:.7rem .9rem;overflow-x:auto}'
  say '.mute{color:var(--mute)} form{display:flex;gap:.5rem;margin-bottom:1.25rem}'
  say 'input[type=search]{flex:1;min-width:0;padding:.55rem .7rem;font-size:1rem;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)}'
  say 'button{padding:.55rem 1rem;font-size:1rem;border-radius:6px;border:1px solid var(--line);background:var(--code);color:var(--fg);cursor:pointer}'
  say 'form.f{display:block} form.f label{display:block;margin:.8rem 0 .2rem} form.f input[type=text],form.f input[type=email]{width:100%;box-sizing:border-box;padding:.55rem .7rem;font-size:1rem;border:1px solid var(--line);border-radius:6px;background:var(--bg);color:var(--fg)} .hp{display:none}'
  say '.tbl{overflow-x:auto} footer{color:var(--mute);font-size:.85rem;margin-top:3rem}'
  say '</style></head><body>'
  say '<header><div><a href="' || Esc(value('SCRIPT_NAME',,'ENVIRONMENT')) || '">rexxpository</a> <span class="mute">&middot; the REXX package index &middot; <a href="' || Esc(value('SCRIPT_NAME',,'ENVIRONMENT')) || '?action=DOWNLOADS" style="font-weight:400;font-size:1rem">get the client</a></span></div></header>'
  say '<main>'
  return

HtmlFooter: procedure
  su = ''
  if SignupEnabled() then su = ' &middot; <a href="' || Esc(value('SCRIPT_NAME',,'ENVIRONMENT')) || '?action=SIGNUP">request an account</a>'
  say '<footer>RXPIP &middot; install with <code>rxpip install &lt;name&gt;</code>' || su || '</footer>'
  say '</main></body></html>'
  return

Web_Home: procedure
  parse arg root, authdir, qstring
  self = Esc(value('SCRIPT_NAME',,'ENVIRONMENT'))
  viewer = Viewer(authdir)
  if IsClosed() & viewer = '' then do
    call HtmlHeader 200, 'rexxpository'
    say '<h1>Private repository</h1>'
    say '<p>This repository is private. The rxpip client shows its packages once you are logged in (<code>rxpip login</code>).</p>'
    if SignupEnabled() then say '<p><a href="' || self || '?action=SIGNUP">Request an account</a></p>'
    call HtmlFooter
    return
  end
  q = QGet(qstring, 'Q')
  if \IsSafeMeta(q, 100) then q = ''
  call HtmlHeader 200, 'rexxpository'
  say '<h1>Packages</h1>'
  say '<form method="get" action="' || self || '"><input type="search" name="q" value="' || Esc(q) || '" placeholder="Search packages" aria-label="Search packages"><button type="submit">Search</button></form>'
  names = VisibleNames(root, authdir, viewer)
  term = translate(q)
  shown = 0
  rows = ''
  do i = 1 to words(names)
    nm = word(names, i)
    ver = LatestVersionOf(root, nm)
    if ver = '' then iterate
    ms = MetaStr(root, nm, ver)
    parse var ms f1 '01'x f2 '01'x f3 '01'x f4 '01'x f5
    if term \= '' & pos(term, translate(nm f4)) = 0 then iterate
    shown = shown + 1
    rows = rows || '<tr><td><a href="' || self || '?action=PKG&amp;name=' || Esc(nm) || '">' || Esc(nm) || '</a></td>' ||,
           '<td>' || Esc(ver) || '</td><td>' || Esc(f4) || '</td><td class="mute">' || Esc(OwnersStr(authdir, nm)) || '</td></tr>' || '0a'x
  end
  if q \= '' then say '<p class="mute">' || shown || ' result(s) for <b>' || Esc(q) || '</b> &middot; <a href="' || self || '">show all</a></p>'
  if shown = 0 then say '<p>No packages found.</p>'
  else do
    say '<div class="tbl"><table><thead><tr><th>Name</th><th>Latest</th><th>Summary</th><th>Owners</th></tr></thead><tbody>'
    call charout , rows
    say '</tbody></table></div>'
  end
  call HtmlFooter
  return

/* ---- the client download page (public; also in a closed repository) ------ */
Web_Downloads: procedure
  parse arg root, qstring
  self = Esc(value('SCRIPT_NAME',,'ENVIRONMENT'))
  call HtmlHeader 200, 'Get the rxpip client'
  say '<h1>Get the rxpip client</h1>'
  say '<p>rxpip installs REXX packages from this repository. Below are the downloads for Windows, Linux and macOS, then the clients for the other REXX interpreters; all behave the same.</p>'
  rv = ClientLatest(root, 'regina')
  if rv \= '' & IsSafeVersion(rv) & FileExists(root || '/.clients/regina/' || rv || '/MANIFEST') then do
    base = Esc(PublicUrl()) || '?action=CLIENT&amp;kind=regina&amp;version=' || Esc(rv) || '&amp;file='
    nl = '0a'x
    say '<h2>Download for your system</h2>'
    say '<p>The standard client runs on <a href="https://regina-rexx.sourceforge.io/">Regina REXX</a> (version ' || Esc(rv) || ').</p>'
    say '<h3>Windows</h3>'
    say '<p>Install Regina for Windows, then save these two files into one folder that is on your PATH: <a href="' || self || '?action=CLIENT&amp;kind=regina&amp;version=' || Esc(rv) || '&amp;file=rxpip.rexx">rxpip.rexx</a> and <a href="' || self || '?action=CLIENT&amp;kind=regina&amp;version=' || Esc(rv) || '&amp;file=rxpip.bat">rxpip.bat</a>. Or in a command prompt:</p>'
    say '<pre>curl.exe -o rxpip.rexx "' || base || 'rxpip.rexx"' || nl || 'curl.exe -o rxpip.bat "' || base || 'rxpip.bat"</pre>'
    say '<h3>Linux</h3>'
    say '<p>Install Regina (<code>sudo apt install regina-rexx</code> or <code>sudo dnf install regina-rexx</code>), then:</p>'
    say '<pre>sudo curl -o /usr/local/bin/rxpip.rexx "' || base || 'rxpip.rexx"' || nl || 'sudo chmod +x /usr/local/bin/rxpip.rexx' || nl || 'sudo ln -sf rxpip.rexx /usr/local/bin/rxpip' || nl || 'rxpip help</pre>'
    say '<h3>macOS</h3>'
    say '<p>Install Regina (<code>brew install regina-rexx</code>), then:</p>'
    say '<pre>sudo curl -o /usr/local/bin/rxpip.rexx "' || base || 'rxpip.rexx"' || nl || 'sudo chmod +x /usr/local/bin/rxpip.rexx' || nl || 'sudo ln -sf rxpip.rexx /usr/local/bin/rxpip' || nl || 'rxpip help</pre>'
    say '<p class="mute">All three need <code>curl</code> and <code>tar</code>, which Windows 10 and later, macOS and Linux include. Later, <code>rxpip update</code> installs newer versions of the client.</p>'
    say '<h2>Other REXX interpreters</h2>'
  end
  kinds = 'regina oorexx netrexx crexx'
  title.1 = 'Regina REXX'
  title.2 = 'ooRexx'
  title.3 = 'NetRexx'
  title.4 = 'cREXX'
  need.1 = 'Regina 3.9 or newer.'
  need.2 = 'ooRexx 5 or newer. Shares the package store with the Regina client.'
  need.3 = 'Java and <code>NetRexxC.jar</code> (set <code>NETREXX_JAR</code> to its path).'
  need.4 = 'cREXX 1.0 beta 3 or newer, with <code>rxc</code>, <code>rxas</code> and <code>rxvm</code> on the PATH (or <code>CREXX_HOME</code> set).'
  how.1 = 'Save the files into a folder on your PATH. On Linux and macOS run <code>chmod +x rxpip.rexx</code> and call it as <code>rxpip.rexx</code> (or <code>regina -a rxpip.rexx</code>); on Windows use <code>rxpip.bat</code>.'
  how.2 = 'Save all files into one folder on your PATH. On Linux and macOS run <code>chmod +x rxpip-oorexx</code>; on Windows use <code>rxpip-oorexx.bat</code>.'
  how.3 = 'Save all files into one folder. On Linux and macOS run <code>chmod +x rxpip-netrexx</code>; on Windows use <code>rxpip-netrexx.bat</code>. The client is compiled the first time you start it.'
  how.4 = 'Save all files into one folder. On Linux and macOS run <code>chmod +x rxpip-crexx</code>; on Windows use <code>rxpip-crexx.bat</code>. The client is compiled the first time you start it.'
  any = 0
  do i = 1 to words(kinds)
    kind = word(kinds, i)
    ver = ClientLatest(root, kind)
    if ver = '' | \IsSafeVersion(ver) | \FileExists(root || '/.clients/' || kind || '/' || ver || '/MANIFEST') then iterate
    any = 1
    dir = root || '/.clients/' || kind || '/' || ver
    files = FileField(dir || '/MANIFEST', 'FILES')
    say '<h2>' || title.i || ' <span class="mute">version ' || Esc(ver) || '</span></h2>'
    say '<p>' || need.i || '</p>'
    say '<div class="tbl"><table><thead><tr><th>File</th><th>Size</th></tr></thead><tbody>'
    do j = 1 to words(files)
      f = word(files, j)
      if \IsSafeFileName(f) then iterate
      sz = stream(dir || '/' || f, 'c', 'query size')
      say '<tr><td><a href="' || self || '?action=CLIENT&amp;kind=' || kind || '&amp;version=' || Esc(ver) || '&amp;file=' || Esc(f) || '">' || Esc(f) || '</a></td><td class="mute">' || sz || ' bytes</td></tr>'
    end
    say '</tbody></table></div>'
    say '<p>' || how.i || '</p>'
  end
  if \any then say '<p>No client has been published here yet.</p>'
  else do
    say '<h2>Then</h2>'
    say '<pre>rxpip search &lt;term&gt;' || '0a'x || 'rxpip install &lt;name&gt;' || '0a'x || 'rxpip update --check</pre>'
    say '<p class="mute">Once installed, <code>rxpip update</code> fetches newer releases of your client from here. The client sends its kind, version and operating system with each request; see the manual for what the server records.</p>'
  end
  call HtmlFooter
  return

Web_Package: procedure
  parse arg root, authdir, qstring
  self = Esc(value('SCRIPT_NAME',,'ENVIRONMENT'))
  viewer = Viewer(authdir)
  name = QGet(qstring, 'NAME')
  ver = QGet(qstring, 'VERSION')
  if \IsSafeToken(name) | (ver \= '' & \IsSafeVersion(ver)) then do
    call HtmlHeader 400, 'Bad request'
    say '<h1>Bad request</h1><p>Invalid package name or version.</p>'
    call HtmlFooter
    return
  end
  if ver = '' then ver = LatestVersionOf(root, name)
  if ver = '' | \FileExists(MetaPath(root, name, ver)) | \CanRead(authdir, viewer, name) then do
    call HtmlHeader 404, 'Not found'
    say '<h1>Not found</h1><p>No such package or version. <a href="' || self || '">Browse all packages</a>.</p>'
    call HtmlFooter
    return
  end
  latest = LatestVersionOf(root, name)
  ms = MetaStr(root, name, ver)
  parse var ms f1 '01'x f2 '01'x f3 '01'x f4 '01'x f5
  call HtmlHeader 200, name ver
  say '<h1>' || Esc(name) || ' <span class="mute">' || Esc(ver) || '</span></h1>'
  if f4 \= '' then say '<p>' || Esc(f4) || '</p>'
  if ver \= latest then say '<p class="mute">This is not the latest version. <a href="' || self || '?action=PKG&amp;name=' || Esc(name) || '">View ' || Esc(latest) || '</a>.</p>'
  say '<h2>Install</h2>'
  say '<pre>rxpip install ' || Esc(name) || '==' || Esc(ver) || '</pre>'
  say '<p>or in a program: <code>/* REQUIRE ' || Esc(name) || ' */</code></p>'
  say '<h2>Details</h2><table><tbody>'
  say '<tr><th>Author</th><td>' || Esc(f3) || '</td></tr>'
  say '<tr><th>Owners</th><td>' || Esc(OwnersStr(authdir, name)) || '</td></tr>'
  reqs = ''
  rq = translate(f5, ' ', ',')
  do i = 1 to words(rq)
    w = word(rq, i)
    parse var w rn '>=' rv
    reqs = reqs || '<a href="' || self || '?action=PKG&amp;name=' || Esc(rn) || '">' || Esc(w) || '</a> '
  end
  if reqs = '' then reqs = '<span class="mute">none</span>'
  say '<tr><th>Requires</th><td>' || reqs || '</td></tr>'
  say '</tbody></table>'
  say '<h2>Files for ' || Esc(ver) || '</h2>'
  recs = ArtifactsStr(root, name, ver)
  if recs = '' then say '<p class="mute">No artifacts.</p>'
  else do
    say '<div class="tbl"><table><thead><tr><th>Kind</th><th>Platform</th><th>Contains</th><th></th></tr></thead><tbody>'
    rest = recs
    do while rest \= ''
      parse var rest one '0a'x rest
      if one = '' then iterate
      parse var one k '01'x p '01'x f
      dl = self || '?action=DOWNLOAD&amp;name=' || Esc(name) || '&amp;version=' || Esc(ver) || '&amp;kind=' || Esc(k) || '&amp;platform=' || Esc(p)
      say '<tr><td>' || Esc(k) || '</td><td>' || Esc(p) || '</td><td>' || Esc(f) || '</td><td><a href="' || dl || '">Download</a></td></tr>'
    end
    say '</tbody></table></div>'
  end
  vs = VersionsStr(root, name)
  say '<h2>Versions</h2><p>'
  do i = words(vs) to 1 by -1
    v = word(vs, i)
    if v = ver then say '<b>' || Esc(v) || '</b>'
    else say '<a href="' || self || '?action=PKG&amp;name=' || Esc(name) || '&amp;version=' || Esc(v) || '">' || Esc(v) || '</a>'
  end
  say '</p>'
  call HtmlFooter
  return

/* =======================================================================
   VISIBILITY  (private packages) and the CLOSED repository
   -----------------------------------------------------------------------
   Per package, under AUTH_DIR (never served):
     visibility/<pkg>.vis   exists and says "private" -> not public
     readers/<pkg>.readers  users who may READ a private package (owners
                            always may) -- one username per line
   RXPIP_CLOSED=1 makes the whole repository private: every read action
   needs a valid token. Reads carry the token in the X-Rxpip-Token header.
   A private package is answered exactly like a package that does not
   exist, so its name cannot be probed.
   ======================================================================= */
IsClosed: procedure
  return value('RXPIP_CLOSED',,'ENVIRONMENT') = '1'

/* the user behind the X-Rxpip-Token header of a read request, or '' */
Viewer: procedure
  parse arg authdir
  token = value('HTTP_X_RXPIP_TOKEN',,'ENVIRONMENT')
  if token = '' then return ''
  if \IsSafeSecret(token) then return ''
  if Sha256Hex('rxpip') = '' then return ''
  return AuthUser(authdir, token)

/* closed repository without a valid token: answer 401 and say no */
ReadGate: procedure
  parse arg viewer
  if IsClosed() & viewer = '' then do
    call Fail 401, 'NO_TOKEN', 'this repository is private: send a valid token (rxpip login)'
    return 0
  end
  return 1

IsPrivate: procedure
  parse arg authdir, pkg
  f = authdir || '/visibility/' || pkg || '.vis'
  if \FileExists(f) then return 0
  return pos('private', Lower(FileField(f, 'VISIBILITY'))) > 0

SetVisibility: procedure
  parse arg authdir, pkg, v
  f = authdir || '/visibility/' || pkg || '.vis'
  if v = 'private' then do
    call EnsureDir authdir || '/visibility'
    call ReplaceFile f, 'VISIBILITY: private' || '0a'x
  end
  else call DelFile f
  return

ReadersStr: procedure
  parse arg authdir, pkg
  f = authdir || '/readers/' || pkg || '.readers'
  out = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = strip(linein(f))
      if l \= '' then out = out l
    end
    call stream f, 'c', 'close'
  end
  return strip(out)

WriteReaders: procedure
  parse arg authdir, pkg, list
  call EnsureDir authdir || '/readers'
  c = ''
  do i = 1 to words(list)
    c = c || word(list, i) || '0a'x
  end
  if c = '' then call DelFile authdir || '/readers/' || pkg || '.readers'
  else call ReplaceFile authdir || '/readers/' || pkg || '.readers', c
  return

/* may viewer ('' = anonymous) read package pkg? */
CanRead: procedure
  parse arg authdir, viewer, pkg
  if IsClosed() & viewer = '' then return 0
  if \IsPrivate(authdir, pkg) then return 1
  if viewer = '' then return 0
  if IsOwner(authdir, pkg, viewer) then return 1
  return wordpos(viewer, ReadersStr(authdir, pkg)) > 0

/* the package names this viewer may see */
VisibleNames: procedure
  parse arg root, authdir, viewer
  all = PackageNamesStr(root)
  out = ''
  do i = 1 to words(all)
    if CanRead(authdir, viewer, word(all, i)) then out = out word(all, i)
  end
  return strip(out)

/* POST: set a package's visibility (owners only) */
Action_Visibility: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  name = HdrOrQuery('HTTP_X_RXPIP_NAME', qs, 'NAME')
  v = Lower(strip(HdrOrQuery('HTTP_X_RXPIP_VALUE', qs, 'VALUE')))
  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid package name'
    return
  end
  if v \= 'public' & v \= 'private' then do
    call Fail 400, 'BAD_VISIBILITY', 'value must be public or private'
    return
  end
  if \IsOwner(authdir, name, u) then do
    call Fail 404, 'NOT_FOUND', "package '" || name || "' not found"
    return
  end
  call SetVisibility authdir, name, v
  call TextHeader
  say 'STATUS: OK'
  say 'NAME:' name
  say 'VISIBILITY:' v
  return

/* POST: READERS (list), ADDREADER, REMOVEREADER -- owners only */
Action_Readers: procedure
  parse arg authdir, method_, act
  u = Authenticate(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  name = HdrOrQuery('HTTP_X_RXPIP_NAME', qs, 'NAME')
  target = HdrOrQuery('HTTP_X_RXPIP_USER', qs, 'USER')
  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid package name'
    return
  end
  if \IsOwner(authdir, name, u) then do
    call Fail 404, 'NOT_FOUND', "package '" || name || "' not found"
    return
  end
  readers = ReadersStr(authdir, name)
  if act = 'ADDREADER' | act = 'REMOVEREADER' then do
    if \IsSafeUser(target) then do
      call Fail 400, 'BAD_USER', 'invalid username'
      return
    end
    if act = 'ADDREADER' then do
      if \UserExists(authdir, target) then do
        call Fail 404, 'NO_SUCH_USER', "no such user '" || target || "'"
        return
      end
      if wordpos(target, readers) = 0 then readers = readers target
    end
    else do
      p = wordpos(target, readers)
      if p = 0 then do
        call Fail 404, 'NOT_A_READER', "'" || target || "' is not a reader of '" || name || "'"
        return
      end
      readers = delword(readers, p, 1)
    end
    call WriteReaders authdir, name, strip(readers)
    readers = ReadersStr(authdir, name)
  end
  call TextHeader
  say 'STATUS: OK'
  say 'NAME:' name
  if IsPrivate(authdir, name) then say 'VISIBILITY: private'
  else say 'VISIBILITY: public'
  say 'READERS:' readers
  return

/* =======================================================================
   USERS, TOKENS, INVITES, OWNERS
   -----------------------------------------------------------------------
   Layout under AUTH_DIR (outside the web root; never served):
     users/<user>.user      CREATED:
     tokens/<id>.tok        USER: / LABEL: / CREATED: / HASH: sha256$salt$hash
     invites/<id>.inv       NOTE: / CREATED: / HASH:      (.used once redeemed)
     owners/<pkg>.owners    one username per line
   A token is  rxp_<8 hex id>_<48 hex secret>  (server generated, shown
   exactly once). The id locates the record in O(1); the whole token is
   verified against the salted hash. Invites look like inv_<id>_<32 hex>.
   Because tokens carry 192 bits of server-chosen randomness, a single
   salted SHA-256 is adequate (a slow KDF only matters for human-chosen
   passwords, and none exist in this design).
   ======================================================================= */

/* usernames: 3-32 chars, lowercase letters, digits, '-' and '_'; lowercase
   only so that case-insensitive filesystems cannot alias two users */
IsSafeUser: procedure
  parse arg u
  if length(u) < 3 | length(u) > 32 then return 0
  if verify(u, 'abcdefghijklmnopqrstuvwxyz0123456789_-') > 0 then return 0
  return left(u, 1) \= '-'

/* value of "KEY: value" in a small record file ('' if absent) */
FileField: procedure
  parse arg file, key
  res = ''
  if \FileExists(file) then return ''
  do while lines(file) > 0
    l = linein(file)
    parse var l k ':' v
    if translate(strip(k)) = translate(key) then do
      res = strip(v)
      leave
    end
  end
  call stream file, 'c', 'close'
  return res

/* atomically replace a file's content (write temp, then rename) */
ReplaceFile: procedure
  parse arg file, content
  tmp = file || '.tmp' || translate(time('L'), '__', ':.') || random(1, 99999)
  call charout tmp, content
  call stream tmp, 'c', 'close'
  call MoveFile tmp, file
  return

/* space-separated file names in dir that end in suffix, suffix removed */
DirBasesStr: procedure
  parse arg dir, suffix
  if \FileIsDir(dir) then return ''
  tmp = TempDir() || '/rxpip_db_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  call ListDirNames dir, tmp
  out = ''
  do while lines(tmp) > 0
    l = strip(linein(tmp))
    if length(l) <= length(suffix) then iterate
    if right(l, length(suffix)) \= suffix then iterate
    out = out || left(l, length(l) - length(suffix)) || ' '
  end
  call stream tmp, 'c', 'close'
  call DelFile tmp
  return strip(out)

UserExists: procedure
  parse arg authdir, u
  return IsSafeUser(u) & FileExists(authdir || '/users/' || u || '.user')

/* ---- tokens ---- */

/* username owning a valid token, or '' (unknown, revoked, malformed all
   look the same to the caller) */
AuthUser: procedure
  parse arg authdir, token
  parse var token pre '_' id '_' sec
  if pre \= 'rxp' | \IsHex(id, 8) | \IsHex(sec, 48) then return ''
  f = authdir || '/tokens/' || id || '.tok'
  if \FileExists(f) then return ''
  if \VerifySecret(token, FileField(f, 'HASH')) then return ''
  u = FileField(f, 'USER')
  if \UserExists(authdir, u) then return ''
  return u

/* mint a token for user; returns the token (the ONLY time it exists in
   clear) or '' on failure */
CreateToken: procedure
  parse arg authdir, user, label
  call EnsureDir authdir || '/tokens'
  do try = 1 to 5
    id = RandomHex(4)
    sec = RandomHex(24)
    if id = '' | sec = '' then return ''
    tok = 'rxp_' || id || '_' || sec
    rec = MakeSecretRecord(tok)
    if rec = '' then return ''
    c = 'USER: ' || user || '0a'x || 'LABEL: ' || label || '0a'x ||,
        'CREATED: ' || date('S') || ' ' || time() || '0a'x ||,
        'HASH: ' || rec || '0a'x
    if WriteNew(authdir || '/tokens/' || id || '.tok', c) then return tok
  end
  return ''

/* ids (space separated) of the tokens belonging to user */
UserTokenIds: procedure
  parse arg authdir, user
  ids = DirBasesStr(authdir || '/tokens', '.tok')
  out = ''
  do i = 1 to words(ids)
    id = word(ids, i)
    if FileField(authdir || '/tokens/' || id || '.tok', 'USER') = user then out = out id
  end
  return strip(out)

/* ---- invites ---- */

CreateInvite: procedure
  parse arg authdir, note
  call EnsureDir authdir || '/invites'
  do try = 1 to 5
    id = RandomHex(4)
    sec = RandomHex(16)
    if id = '' | sec = '' then return ''
    inv = 'inv_' || id || '_' || sec
    rec = MakeSecretRecord(inv)
    if rec = '' then return ''
    c = 'NOTE: ' || note || '0a'x || 'CREATED: ' || date('S') || ' ' || time() || '0a'x ||,
        'HASH: ' || rec || '0a'x
    if WriteNew(authdir || '/invites/' || id || '.inv', c) then return inv
  end
  return ''

/* claim an invite: 1 if this caller consumed it. The claim is a rename,
   which only one of several concurrent callers can win (on Unix). */
RedeemInvite: procedure
  parse arg authdir, inv
  parse var inv pre '_' id '_' sec
  if pre \= 'inv' | \IsHex(id, 8) | \IsHex(sec, 32) then return 0
  f = authdir || '/invites/' || id || '.inv'
  if \FileExists(f) then return 0
  if \VerifySecret(inv, FileField(f, 'HASH')) then return 0
  if IsWindows() then 'move "' || translate(f,'\','/') || '" "' || translate(f,'\','/') || '.used" >nul 2>nul'
  else 'mv "' || f || '" "' || f || '.used" 2>/dev/null'
  return rc = 0

UnredeemInvite: procedure
  parse arg authdir, inv
  parse var inv pre '_' id '_' sec
  f = authdir || '/invites/' || id || '.inv'
  call MoveFile f || '.used', f
  return

/* ---- owners ---- */

OwnersStr: procedure
  parse arg authdir, pkg
  f = authdir || '/owners/' || pkg || '.owners'
  out = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = strip(linein(f))
      if l \= '' then out = out l
    end
    call stream f, 'c', 'close'
  end
  return strip(out)

IsOwner: procedure
  parse arg authdir, pkg, user
  return wordpos(user, OwnersStr(authdir, pkg)) > 0

WriteOwners: procedure
  parse arg authdir, pkg, list
  call EnsureDir authdir || '/owners'
  c = ''
  do i = 1 to words(list)
    c = c || word(list, i) || '0a'x
  end
  call ReplaceFile authdir || '/owners/' || pkg || '.owners', c
  return

/* ---- HTTP actions that need a logged-in user ---- */

/* common gate: POST only, token only in the header; returns the username,
   or '' after having already sent the error response */
Authenticate: procedure
  parse arg authdir, method_
  if translate(method_) \= 'POST' then do
    call Fail 405, 'METHOD_NOT_ALLOWED', 'this action requires POST'
    return ''
  end
  if QGet(value('QUERY_STRING',,'ENVIRONMENT'), 'TOKEN') \= '' then do
    call Fail 400, 'TOKEN_IN_URL', 'send the token only in the X-Rxpip-Token header, never in the URL (URLs are logged)'
    return ''
  end
  token = value('HTTP_X_RXPIP_TOKEN',,'ENVIRONMENT')
  if token = '' then do
    call Fail 401, 'NO_TOKEN', 'this action requires the X-Rxpip-Token header'
    return ''
  end
  if \IsSafeSecret(token) then do
    call Fail 401, 'BAD_TOKEN', 'malformed token'
    return ''
  end
  if Sha256Hex('rxpip') = '' then do
    call Fail 500, 'SERVER_NO_HASH', 'server has no SHA-256 tool (sha256sum, shasum or PowerShell)'
    return ''
  end
  u = AuthUser(authdir, token)
  if u = '' then call Fail 401, 'BAD_TOKEN', 'unknown or revoked token'
  return u

/* a response that carries a secret must never be cached */
SecretHeader: procedure
  say 'Content-Type: text/plain; charset=utf-8'
  say 'Cache-Control: no-store'
  say ''
  return

/* invite-only sign-up: X-Rxpip-Invite + X-Rxpip-User -> user and first token */
Action_Register: procedure
  parse arg authdir, method_
  if translate(method_) \= 'POST' then do
    call Fail 405, 'METHOD_NOT_ALLOWED', 'register requires POST'
    return
  end
  inv = value('HTTP_X_RXPIP_INVITE',,'ENVIRONMENT')
  user = value('HTTP_X_RXPIP_USER',,'ENVIRONMENT')
  if \IsSafeUser(user) then do
    call Fail 400, 'BAD_USER', 'username must be 3-32 characters: a-z 0-9 _ - (lowercase)'
    return
  end
  if length(inv) > 128 | verify(inv, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_') > 0 | inv = '' then do
    call Fail 403, 'BAD_INVITE', 'invalid, used or missing invite code'
    return
  end
  if Sha256Hex('rxpip') = '' then do
    call Fail 500, 'SERVER_NO_HASH', 'server has no SHA-256 tool'
    return
  end
  if UserExists(authdir, user) then do
    call Fail 409, 'USER_EXISTS', "user '" || user || "' already exists"
    return
  end
  if \RedeemInvite(authdir, inv) then do
    call Fail 403, 'BAD_INVITE', 'invalid, used or missing invite code'
    return
  end
  call EnsureDir authdir || '/users'
  if \WriteNew(authdir || '/users/' || user || '.user', 'CREATED: ' || date('S') || ' ' || time() || '0a'x) then do
    call UnredeemInvite authdir, inv
    call Fail 409, 'USER_EXISTS', "user '" || user || "' already exists"
    return
  end
  tok = CreateToken(authdir, user, 'registration')
  if tok = '' then do
    call DelFile authdir || '/users/' || user || '.user'
    call UnredeemInvite authdir, inv
    call Fail 500, 'SERVER_NO_RANDOM', 'server could not create a token'
    return
  end
  call SecretHeader
  say 'STATUS: OK'
  say 'USER:' user
  say 'TOKEN:' tok
  say 'MESSAGE: account created. Store this token now; it is shown only once.'
  return

/* ---- moderated web sign-up ------------------------------------------
   Visitor fills in a form (name, e-mail, location). The server stores a
   pending request and mails the ADMIN a review link. The admin opens the
   link (a page with Approve / Reject buttons -- a GET never changes
   anything, so mail scanners cannot approve by prefetching). Approval
   creates a single-use invite and mails it to the applicant, who then
   runs  rxpip register --user=<name> --invite=<code>.
   Needs: RXPIP_ADMIN_EMAIL (sign-up is off when unset) and a working
   sendmail (or RXPIP_SENDMAIL to name another command that reads a
   message on stdin). RXPIP_PUBLIC_URL = full URL of this script, used in
   links; RXPIP_MAIL_FROM = sender address. */

SignupEnabled: procedure
  return IsSafeEmail(value('RXPIP_ADMIN_EMAIL',,'ENVIRONMENT'))

IsSafeEmail: procedure
  parse arg e
  if length(e) < 5 | length(e) > 100 then return 0
  if verify(e, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._%+-@') > 0 then return 0
  if countstr('@', e) \= 1 then return 0
  parse var e loc '@' dom
  if loc = '' | dom = '' | pos('.', dom) = 0 then return 0
  if left(dom, 1) = '.' | right(dom, 1) = '.' | pos('..', e) > 0 then return 0
  return left(e, 1) \= '-'

PublicUrl: procedure
  u = value('RXPIP_PUBLIC_URL',,'ENVIRONMENT')
  if u \= '' then return u
  sch = 'http'
  if translate(value('HTTPS',,'ENVIRONMENT')) = 'ON' then sch = 'https'
  return sch || '://' || value('SERVER_NAME',,'ENVIRONMENT') || value('SCRIPT_NAME',,'ENVIRONMENT')

/* send a plain-text mail; 1 = handed to the mail system */
SendMail: procedure
  parse arg to, subject, body
  if IsWindows() then return 0
  from = value('RXPIP_MAIL_FROM',,'ENVIRONMENT')
  if from = '' then from = 'rxpip@' || value('SERVER_NAME',,'ENVIRONMENT')
  if \IsSafeEmail(from) | \IsSafeEmail(to) | \IsSafeMeta(subject, 200) then return 0
  cmd = value('RXPIP_SENDMAIL',,'ENVIRONMENT')
  if cmd = '' then cmd = '/usr/sbin/sendmail -t -i'
  f = TempDir() || '/rxpip_mail_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  msg = 'From: ' || from || '0a'x || 'To: ' || to || '0a'x || 'Subject: ' || subject || '0a'x ||,
        'Content-Type: text/plain; charset=utf-8' || '0a'x || '0a'x || body || '0a'x
  call charout f, msg
  call stream f, 'c', 'close'
  address system cmd '< "' || f || '" > /dev/null 2>&1'
  r = (rc = 0)
  call DelFile f
  return r

/* pending request ids; expired ones are removed on the way */
PendingIds: procedure
  parse arg authdir
  ids = DirBasesStr(authdir || '/requests', '.req')
  out = ''
  do i = 1 to words(ids)
    f = authdir || '/requests/' || word(ids, i) || '.req'
    d = FileField(f, 'DAY')
    if datatype(d, 'W') & date('B') - d > 14 then call DelFile f
    else out = out word(ids, i)
  end
  return strip(out)

Web_Signup: procedure
  parse arg authdir, method_, clen
  self = Esc(value('SCRIPT_NAME',,'ENVIRONMENT'))
  if \SignupEnabled() then do
    call HtmlHeader 404, 'Sign up'
    say '<h1>Sign up</h1><p>Online sign-up is not enabled on this repository. Ask the administrator for an invite code.</p>'
    call HtmlFooter
    return
  end
  user = ''; email = ''; loc = ''; err = ''
  if translate(method_) = 'POST' then do
    if \datatype(clen, 'W') | clen < 1 | clen > 2000 then do
      call HtmlHeader 413, 'Sign up'
      say '<h1>Sign up</h1><p>Request too large.</p>'
      call HtmlFooter
      return
    end
    body = charin(, , clen)
    user = Lower(strip(QGet(body, 'USER')))
    email = strip(QGet(body, 'EMAIL'))
    loc = strip(QGet(body, 'LOCATION'))
    hp = QGet(body, 'WEBSITE')
    if hp \= '' then err = 'Request rejected.'
    else if \IsSafeUser(user) then err = 'Name: 3-32 characters, a-z 0-9 _ - (lowercase), not starting with -.'
    else if \IsSafeEmail(email) then err = 'Please enter a valid e-mail address.'
    else if loc = '' | \IsSafeMeta(loc, 80) then err = 'Location: 1-80 characters, no control characters.'
    else if UserExists(authdir, user) then err = 'That name is already taken.'
    else if Sha256Hex('rxpip') = '' then err = 'The server cannot process sign-ups right now.'
    else do
      ids = PendingIds(authdir)
      ip = value('REMOTE_ADDR',,'ENVIRONMENT')
      same = 0
      dup = 0
      do i = 1 to words(ids)
        f = authdir || '/requests/' || word(ids, i) || '.req'
        if FileField(f, 'USER') = user then dup = 1
        if ip \= '' & FileField(f, 'IP') = ip then same = same + 1
      end
      if dup then err = 'A request for that name is already waiting for approval.'
      else if words(ids) >= 100 | same >= 3 then err = 'Too many pending requests. Please try again later.'
    end
    if err = '' then do
      call EnsureDir authdir || '/requests'
      id = RandomHex(4)
      key = RandomHex(16)
      rec = ''
      if id \= '' & key \= '' then rec = MakeSecretRecord(key)
      if rec = '' then err = 'The server could not create a request.'
      else do
        c = 'USER: ' || user || '0a'x || 'EMAIL: ' || email || '0a'x || 'LOCATION: ' || loc || '0a'x ||,
            'IP: ' || value('REMOTE_ADDR',,'ENVIRONMENT') || '0a'x || 'DAY: ' || date('B') || '0a'x ||,
            'CREATED: ' || date('S') || ' ' || time() || '0a'x || 'HASH: ' || rec || '0a'x
        rf = authdir || '/requests/' || id || '.req'
        if \WriteNew(rf, c) then err = 'The server could not create a request.'
        else do
          link = PublicUrl() || '?action=REVIEW&req=' || id || '&key=' || key
          mb = 'New rxpip account request' || '0a'x || '0a'x ||,
               'Name:     ' || user || '0a'x || 'E-mail:   ' || email || '0a'x ||,
               'Location: ' || loc || '0a'x || 'From IP:  ' || value('REMOTE_ADDR',,'ENVIRONMENT') || '0a'x || '0a'x ||,
               'Review (approve or reject):' || '0a'x || link || '0a'x || '0a'x ||,
               'The link is valid for 14 days. Do not forward it.'
          if \SendMail(value('RXPIP_ADMIN_EMAIL',,'ENVIRONMENT'), 'rxpip account request: ' || user, mb) then do
            call DelFile rf
            err = 'The server could not send the notification mail. Please try again later.'
          end
        end
      end
    end
    if err = '' then do
      call HtmlHeader 200, 'Sign up'
      say '<h1>Request received</h1>'
      say '<p>Thank you, <b>' || Esc(user) || '</b>. Your request has been sent to the administrator.'
      say 'When it is approved you will receive an invite code at <b>' || Esc(email) || '</b>.</p>'
      call HtmlFooter
      return
    end
  end
  if err \= '' then call HtmlHeader 400, 'Sign up'
  else call HtmlHeader 200, 'Sign up'
  say '<h1>Request an account</h1>'
  say '<p class="mute">Accounts are approved by the administrator. You will get an invite code by e-mail.</p>'
  if err \= '' then say '<p><b>' || Esc(err) || '</b></p>'
  say '<form class="f" method="post" action="' || self || '?action=SIGNUP">'
  say '<label for="user">Name (your login, e.g. mike)</label><input type="text" id="user" name="user" maxlength="32" required value="' || Esc(user) || '">'
  say '<label for="email">E-mail address</label><input type="email" id="email" name="email" maxlength="100" required value="' || Esc(email) || '">'
  say '<label for="loc">Location (city, country)</label><input type="text" id="loc" name="location" maxlength="80" required value="' || Esc(loc) || '">'
  say '<div class="hp"><label>Leave empty <input type="text" name="website" tabindex="-1" autocomplete="off"></label></div>'
  say '<p><button type="submit">Send request</button></p></form>'
  call HtmlFooter
  return

Web_Review: procedure
  parse arg authdir, method_, clen, qstring
  self = Esc(value('SCRIPT_NAME',,'ENVIRONMENT'))
  post = (translate(method_) = 'POST')
  if post then do
    if \datatype(clen, 'W') | clen < 1 | clen > 2000 then clen = 0
    body = charin(, , clen)
    id = QGet(body, 'REQ'); key = QGet(body, 'KEY'); decision = translate(QGet(body, 'DECISION'))
  end
  else do
    id = QGet(qstring, 'REQ'); key = QGet(qstring, 'KEY'); decision = ''
  end
  f = authdir || '/requests/' || id || '.req'
  ok = IsHex(id, 8) & IsHex(key, 32) & FileExists(f)
  if ok then ok = VerifySecret(key, FileField(f, 'HASH'))
  if ok then do
    d = FileField(f, 'DAY')
    if \datatype(d, 'W') | date('B') - d > 14 then do
      call DelFile f
      ok = 0
    end
  end
  if \ok then do
    call HtmlHeader 404, 'Review'
    say '<h1>Request not found</h1><p>The link is invalid, expired, or the request was already handled.</p>'
    call HtmlFooter
    return
  end
  user = FileField(f, 'USER'); email = FileField(f, 'EMAIL'); loc = FileField(f, 'LOCATION')
  if post & decision = 'REJECT' then do
    call DelFile f
    call HtmlHeader 200, 'Rejected'
    say '<h1>Rejected</h1><p>The request from <b>' || Esc(user) || '</b> was discarded.</p>'
    call HtmlFooter
    return
  end
  if post & decision = 'APPROVE' then do
    if UserExists(authdir, user) then do
      call DelFile f
      call HtmlHeader 409, 'Review'
      say '<h1>Already exists</h1><p>A user named <b>' || Esc(user) || '</b> exists already; the request was discarded.</p>'
      call HtmlFooter
      return
    end
    inv = CreateInvite(authdir, 'web sign-up: ' || user || ' <' || email || '>')
    if inv = '' then do
      call HtmlHeader 500, 'Review'
      say '<h1>Error</h1><p>The server could not create an invite.</p>'
      call HtmlFooter
      return
    end
    parse var inv . '_' iid '_' .
    mb = 'Your rxpip account request has been approved.' || '0a'x || '0a'x ||,
         'Name:        ' || user || '0a'x || 'Invite code: ' || inv || '0a'x || '0a'x ||,
         'Create your account (the code works once):' || '0a'x ||,
         '  rxpip register --user=' || user || ' --invite=' || inv || '0a'x || '0a'x ||,
         'Repository: ' || PublicUrl() || '0a'x
    if \SendMail(email, 'Your rxpip account is approved', mb) then do
      call DelFile authdir || '/invites/' || iid || '.inv'
      call HtmlHeader 500, 'Review'
      say '<h1>Mail failed</h1><p>The invite mail to the applicant could not be sent. The request is still pending; try again.</p>'
      call HtmlFooter
      return
    end
    call DelFile f
    call HtmlHeader 200, 'Approved'
    say '<h1>Approved</h1><p>An invite code was e-mailed to <b>' || Esc(email) || '</b> for <b>' || Esc(user) || '</b>.</p>'
    call HtmlFooter
    return
  end
  call HtmlHeader 200, 'Review account request'
  say '<h1>Account request</h1>'
  say '<table><tr><th>Name</th><td>' || Esc(user) || '</td></tr><tr><th>E-mail</th><td>' || Esc(email) || '</td></tr>'
  say '<tr><th>Location</th><td>' || Esc(loc) || '</td></tr><tr><th>Requested</th><td>' || Esc(FileField(f, 'CREATED')) || '</td></tr></table>'
  say '<form class="f" method="post" action="' || self || '?action=REVIEW">'
  say '<input type="hidden" name="req" value="' || Esc(id) || '"><input type="hidden" name="key" value="' || Esc(key) || '">'
  say '<p><button type="submit" name="decision" value="approve">Approve</button> '
  say '<button type="submit" name="decision" value="reject">Reject</button></p></form>'
  call HtmlFooter
  return

Action_Whoami: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return
  call TextHeader
  say 'STATUS: OK'
  say 'USER:' u
  return

Action_NewToken: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return
  label = HdrOrQuery('HTTP_X_RXPIP_LABEL', value('QUERY_STRING',,'ENVIRONMENT'), 'LABEL')
  if label = '' then label = 'token'
  if \IsSafeMeta(label, 40) then do
    call Fail 400, 'BAD_LABEL', 'label: max 40 plain-text characters'
    return
  end
  if words(UserTokenIds(authdir, u)) >= 20 then do
    call Fail 409, 'TOO_MANY_TOKENS', 'at most 20 tokens per user; revoke one first'
    return
  end
  tok = CreateToken(authdir, u, label)
  if tok = '' then do
    call Fail 500, 'SERVER_NO_RANDOM', 'server could not create a token'
    return
  end
  call SecretHeader
  say 'STATUS: OK'
  say 'USER:' u
  say 'TOKEN:' tok
  say 'MESSAGE: new token created. Store it now; it is shown only once.'
  return

Action_Tokens: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return
  ids = UserTokenIds(authdir, u)
  call TextHeader
  say 'STATUS: OK'
  say 'COUNT:' words(ids)
  say ''
  do i = 1 to words(ids)
    id = word(ids, i)
    f = authdir || '/tokens/' || id || '.tok'
    say 'TOKEN_ID:' id
    say 'LABEL:' FileField(f, 'LABEL')
    say 'CREATED:' FileField(f, 'CREATED')
    say ''
  end
  return

/* revoke one of your own tokens by id (X-Rxpip-Token-Id) */
Action_Revoke: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return
  id = HdrOrQuery('HTTP_X_RXPIP_TOKEN_ID', value('QUERY_STRING',,'ENVIRONMENT'), 'ID')
  if \IsHex(id, 8) then do
    call Fail 400, 'BAD_TOKEN_ID', 'token id is 8 hex characters (see action TOKENS)'
    return
  end
  f = authdir || '/tokens/' || id || '.tok'
  if FileField(f, 'USER') \= u then do
    call Fail 404, 'NOT_FOUND', 'no such token among yours'
    return
  end
  call DelFile f
  call TextHeader
  say 'STATUS: OK'
  say 'MESSAGE: token' id 'revoked'
  return

Action_Owners: procedure
  parse arg authdir, qstring
  viewer = Viewer(authdir)
  if \ReadGate(viewer) then return
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid package name'
    return
  end
  o = OwnersStr(authdir, name)
  if o = '' | \CanRead(authdir, viewer, name) then do
    call Fail 404, 'NOT_FOUND', "no owners recorded for '" || name || "'"
    return
  end
  call TextHeader
  say 'STATUS: OK'
  say 'NAME:' name
  say 'OWNERS:' o
  return

/* mode ADD or REMOVE; any current owner may change the list */
Action_ChangeOwner: procedure
  parse arg authdir, method_, mode
  u = Authenticate(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  name = HdrOrQuery('HTTP_X_RXPIP_NAME', qs, 'NAME')
  target = HdrOrQuery('HTTP_X_RXPIP_USER', qs, 'USER')
  if \IsSafeToken(name) then do
    call Fail 400, 'BAD_NAME', 'invalid package name'
    return
  end
  if \IsSafeUser(target) then do
    call Fail 400, 'BAD_USER', 'invalid username'
    return
  end
  owners = OwnersStr(authdir, name)
  if owners = '' then do
    call Fail 404, 'NOT_FOUND', "package '" || name || "' has no owners (not published yet)"
    return
  end
  if wordpos(u, owners) = 0 then do
    call Fail 403, 'FORBIDDEN', "you are not an owner of '" || name || "'"
    return
  end
  if mode = 'ADD' then do
    if \UserExists(authdir, target) then do
      call Fail 404, 'NO_SUCH_USER', "no such user '" || target || "'"
      return
    end
    if wordpos(target, owners) = 0 then call WriteOwners authdir, name, owners target
  end
  else do
    p = wordpos(target, owners)
    if p = 0 then do
      call Fail 404, 'NOT_AN_OWNER', "'" || target || "' is not an owner of '" || name || "'"
      return
    end
    if words(owners) = 1 then do
      call Fail 409, 'LAST_OWNER', 'cannot remove the last owner'
      return
    end
    call WriteOwners authdir, name, delword(owners, p, 1)
  end
  call TextHeader
  say 'STATUS: OK'
  say 'NAME:' name
  say 'OWNERS:' OwnersStr(authdir, name)
  return

/* =======================================================================
   ADMIN MODE (command line only)
   -----------------------------------------------------------------------
   Run on the server by the operator, as the web user so file ownership is
   right:   sudo -u apache env RXPIP_REPO_ROOT=... regina -a rxpip_server.rexx admin <cmd>
   It is entered only when GATEWAY_INTERFACE is unset, i.e. never via
   Apache/CGI, so there is no HTTP-reachable admin surface.
   ======================================================================= */
/* =======================================================================
   CLIENT RELEASES, STATISTICS and the ADMINISTRATOR role
   -----------------------------------------------------------------------
   repo/.clients/<kind>/<version>/  the files of a client release (kind =
                                    regina, oorexx, netrexx or crexx) and
                                    MANIFEST (FILES:/MIN:)
   repo/.clients/<kind>/LATEST      the current version
   repo/.stats/<yyyymmdd>.log       one line per request or event:
                                    time|REQ|action|kind|version|os|uid
                                    time|DL|pkg|version|artifact|kind|version|os|uid
                                    time|PUB|pkg|version|artifact|kind|version|os|uid
   repo/.stats/salt                 secret for the daily client id
   .auth/admins                     one administrator per line

   The statistics hold NO addresses and NO tokens: a client is only a
   12-character hash of (address, day, secret salt), which cannot be
   followed from one day to the next. Nothing here is served to the
   public; only administrators can read it (ADMINSTATS, admin stats).
   Logs older than 400 days are deleted. RXPIP_NOSTATS=1 switches the
   recording off.
   ======================================================================= */

/* "kind|version|os" from the X-Rxpip-Client header (regina/1.2.0 (linux)) */
ClientInfo: procedure
  h = value('HTTP_X_RXPIP_CLIENT',,'ENVIRONMENT')
  if h = '' | length(h) > 60 then return 'unknown|-|-'
  if verify(h, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./()_- ') > 0 then return 'unknown|-|-'
  parse var h kind '/' rest
  parse var rest ver '(' os ')' .
  kind = Lower(strip(kind)); ver = strip(ver); os = translate(Lower(strip(os)), '_', ' ')
  if kind = '' | ver = '' then return 'unknown|-|-'
  if os = '' then os = '-'
  return kind || '|' || ver || '|' || os

/* the pseudonymous id of the caller for today */
DailyId: procedure
  parse arg statdir, day
  salt = statdir || '/salt'
  if \FileExists(salt) then do
    s = RandomHex(16)
    if s = '' then return 'x'
    call WriteNew salt, s || '0a'x
  end
  sv = ''
  if FileExists(salt) then do
    sv = strip(linein(salt))
    call stream salt, 'c', 'close'
  end
  h = Sha256Hex(value('REMOTE_ADDR',,'ENVIRONMENT') || '|' || day || '|' || sv)
  if h = '' then return 'x'
  return left(h, 12)

/* append one line to today's log; type REQ, DL or PUB */
LogEvent: procedure
  parse arg statdir, type, a1, a2, a3
  if value('RXPIP_NOSTATS',,'ENVIRONMENT') = '1' then return
  call EnsureDir statdir
  day = date('S')
  f = statdir || '/' || day || '.log'
  fresh = \FileExists(f)
  line = time() || '|' || type
  if type = 'REQ' then line = line || '|' || a1
  else line = line || '|' || a1 || '|' || a2 || '|' || a3
  line = line || '|' || ClientInfo() || '|' || DailyId(statdir, day)
  call charout f, line || '0a'x
  call stream f, 'c', 'close'
  if fresh then call PruneStats statdir
  return

PruneStats: procedure
  parse arg statdir
  tmp = TempDir() || '/rxpip_st_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  call ListDirNames statdir, tmp
  cutoff = date('B') - 400
  do while lines(tmp) > 0
    n = strip(linein(tmp))
    if length(n) = 12 & right(n, 4) = '.log' & datatype(left(n, 8), 'W') then do
      if date('B', left(n, 8), 'S') < cutoff then call DelFile statdir || '/' || n
    end
  end
  call stream tmp, 'c', 'close'
  call DelFile tmp
  return

/* ---- administrators ----------------------------------------------------- */
AdminsStr: procedure
  parse arg authdir
  f = authdir || '/admins'
  out = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = strip(linein(f))
      if l \= '' then out = out l
    end
    call stream f, 'c', 'close'
  end
  return strip(out)

IsAdmin: procedure
  parse arg authdir, user
  return user \= '' & wordpos(user, AdminsStr(authdir)) > 0

WriteAdmins: procedure
  parse arg authdir, list
  c = ''
  do i = 1 to words(list)
    c = c || word(list, i) || '0a'x
  end
  call ReplaceFile authdir || '/admins', c
  return

/* like Authenticate, and the user must be an administrator */
AuthenticateAdmin: procedure
  parse arg authdir, method_
  u = Authenticate(authdir, method_)
  if u = '' then return ''
  if \IsAdmin(authdir, u) then do
    call Fail 403, 'FORBIDDEN', 'administrators only'
    return ''
  end
  return u

/* ---- client releases ---------------------------------------------------- */
ClientLatest: procedure
  parse arg root, kind
  f = root || '/.clients/' || kind || '/LATEST'
  if \FileExists(f) then return ''
  v = strip(linein(f))
  call stream f, 'c', 'close'
  return v

/* GET action=CLIENT&kind=K [&version=V] [&file=F]
   no file: the manifest; with file: the bytes. Public, also in a closed
   repository (clients must be able to update themselves). */
Action_Client: procedure
  parse arg root, qstring
  kind = Lower(QGet(qstring, 'KIND'))
  if \IsSafeToken(kind) then do
    call Fail 400, 'BAD_KIND', 'invalid client kind'
    return
  end
  ver = QGet(qstring, 'VERSION')
  if ver = '' then ver = ClientLatest(root, kind)
  if ver = '' | \IsSafeVersion(ver) | \FileExists(root || '/.clients/' || kind || '/' || ver || '/MANIFEST') then do
    call Fail 404, 'NOT_FOUND', 'no client release for ' || kind
    return
  end
  dir = root || '/.clients/' || kind || '/' || ver
  files = FileField(dir || '/MANIFEST', 'FILES')
  file = QGet(qstring, 'FILE')
  if file = '' then do
    call TextHeader
    say 'STATUS: OK'
    say 'KIND:' kind
    say 'VERSION:' ver
    say 'LATEST:' ClientLatest(root, kind)
    say 'MIN:' FileField(dir || '/MANIFEST', 'MIN')
    say 'FILES:' files
    return
  end
  if wordpos(file, files) = 0 | \IsSafeFileName(file) then do
    call Fail 404, 'NOT_FOUND', 'no such file in the release'
    return
  end
  path = dir || '/' || file
  sz = stream(path, 'c', 'query size')
  say 'Content-Type: application/octet-stream'
  say 'Content-Disposition: attachment; filename="' || file || '"'
  say 'X-Content-Type-Options: nosniff'
  say 'Content-Length:' sz
  say ''
  data = charin(path, 1, sz)
  call stream path, 'c', 'close'
  call charout , data
  return

/* POST (administrator): body = tar.gz of the release files; headers
   X-Rxpip-Kind, X-Rxpip-Version, optional X-Rxpip-Min (oldest client that
   still works). Releases are immutable. */
Action_AdminClient: procedure
  parse arg root, authdir, method_, clen, maxup
  u = AuthenticateAdmin(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  kind = Lower(strip(HdrOrQuery('HTTP_X_RXPIP_KIND', qs, 'KIND')))
  ver = HdrOrQuery('HTTP_X_RXPIP_VERSION', qs, 'VERSION')
  minv = HdrOrQuery('HTTP_X_RXPIP_MIN', qs, 'MIN')
  if \IsSafeToken(kind) | \IsSafeVersion(ver) | (minv \= '' & \IsSafeVersion(minv)) then do
    call Fail 400, 'BAD_RELEASE', 'kind, version (and min) must be valid'
    return
  end
  if \datatype(clen, 'W') then clen = 0
  if clen < 1 | clen > maxup then do
    call Fail 400, 'BAD_BODY', 'missing or too large release archive'
    return
  end
  dir = root || '/.clients/' || kind || '/' || ver
  if FileExists(dir || '/MANIFEST') then do
    call Fail 409, 'ALREADY_EXISTS', 'client release ' || kind || ' ' || ver || ' already exists'
    return
  end
  stage = root || '/.staging'
  call EnsureDir stage
  stage = stage || '/client_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  data = charin(, , clen)
  call charout stage, data
  call stream stage, 'c', 'close'
  data = ''
  v = ValidateArchive(stage)
  parse var v vstat '01'x vrest
  if vstat \= 'OK' then do
    call DelFile stage
    call Fail 400, 'BAD_ARCHIVE', vrest
    return
  end
  call EnsureDir dir
  'tar xzf "' || stage || '" -C "' || dir || '" 2>' || NullSink()
  call DelFile stage
  call ReplaceFile dir || '/MANIFEST', 'FILES: ' || vrest || '0a'x || 'MIN: ' || minv || '0a'x
  /* LATEST only moves forward */
  cur = ClientLatest(root, kind)
  if cur = '' | CompareVersions(ver, cur) > 0 then call ReplaceFile root || '/.clients/' || kind || '/LATEST', ver || '0a'x
  call TextHeader
  say 'STATUS: OK'
  say 'KIND:' kind
  say 'VERSION:' ver
  say 'FILES:' vrest
  say 'LATEST:' ClientLatest(root, kind)
  return

/* ---- administrator actions ------------------------------------------------ */
Action_AdminUsers: procedure
  parse arg authdir, method_
  u = AuthenticateAdmin(authdir, method_)
  if u = '' then return
  names = DirBasesStr(authdir || '/users', '.user')
  call TextHeader
  say 'STATUS: OK'
  say 'COUNT:' words(names)
  say ''
  do i = 1 to words(names)
    nm = word(names, i)
    adm = ''
    if IsAdmin(authdir, nm) then adm = ' admin'
    say 'USER:' nm || ' tokens:' words(UserTokenIds(authdir, nm)) || adm
  end
  return

Action_AdminLock: procedure
  parse arg authdir, method_
  u = AuthenticateAdmin(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  target = HdrOrQuery('HTTP_X_RXPIP_USER', qs, 'USER')
  if \IsSafeUser(target) | \UserExists(authdir, target) then do
    call Fail 404, 'NO_SUCH_USER', 'no such user'
    return
  end
  ids = UserTokenIds(authdir, target)
  do i = 1 to words(ids)
    call DelFile authdir || '/tokens/' || word(ids, i) || '.tok'
  end
  call TextHeader
  say 'STATUS: OK'
  say 'USER:' target
  say 'REVOKED:' words(ids)
  return

Action_AdminStats: procedure
  parse arg root, authdir, method_
  u = AuthenticateAdmin(authdir, method_)
  if u = '' then return
  qs = value('QUERY_STRING',,'ENVIRONMENT')
  days = HdrOrQuery('HTTP_X_RXPIP_DAYS', qs, 'DAYS')
  call TextHeader
  say 'STATUS: OK'
  say StatsReport(root, days)
  return

/* the report: plain text, also used by `admin stats` on the server */
StatsReport: procedure
  parse arg root, days
  if \datatype(days, 'W') then days = 30
  if days < 1 then days = 1
  if days > 400 then days = 400
  statdir = root || '/.stats'
  tmp = TempDir() || '/rxpip_sr_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  call ListDirNames statdir, tmp
  from = date('B') - days + 1
  files = ''
  if FileExists(tmp) then do
    do while lines(tmp) > 0
      n = strip(linein(tmp))
      if length(n) = 12 & right(n, 4) = '.log' & datatype(left(n, 8), 'W') then do
        if date('B', left(n, 8), 'S') >= from then files = files left(n, 8)
      end
    end
    call stream tmp, 'c', 'close'
  end
  call DelFile tmp
  nreq = 0; ndl = 0; npub = 0
  ckeys = ''; pkeys = ''; dayrows = ''
  do fi = 1 to words(files)
    day = word(files, fi)
    f = statdir || '/' || day || '.log'
    dreq = 0; dids = ''
    do while lines(f) > 0
      l = linein(f)
      parse var l tm '|' type '|' rest
      if type = 'REQ' then do
        parse var rest act '|' ck '|' cv '|' cos '|' uid
        nreq = nreq + 1; dreq = dreq + 1
        if uid \= '' & wordpos(uid, dids) = 0 then dids = dids uid
        if uid \= '' then do
          ckey = ck || '~' || cv || '~' || cos
          if wordpos(ckey, ckeys) = 0 then do
            ckeys = ckeys ckey
            cmarks.ckey = ''
          end
          mark = day || ':' || uid
          if wordpos(mark, cmarks.ckey) = 0 then cmarks.ckey = cmarks.ckey mark
        end
      end
      else if type = 'DL' then do
        parse var rest pk '|' pv '|' pa '|' ck '|' cv '|' cos '|' uid
        ndl = ndl + 1
        if wordpos(pk, pkeys) = 0 then do
          pkeys = pkeys pk
          pdl.pk = 0; pdays.pk = ''
        end
        pdl.pk = pdl.pk + 1
        mark = day || ':' || uid
        if wordpos(mark, pdays.pk) = 0 then pdays.pk = pdays.pk mark
      end
      else if type = 'PUB' then npub = npub + 1
    end
    call stream f, 'c', 'close'
    dayrows = dayrows || '  ' || day || '  requests ' || right(dreq, 5) || '  clients ' || right(words(dids), 4) || '0a'x
  end
  out = 'PERIOD: last ' || days || ' day(s), ' || words(files) || ' with data' || '0a'x
  out = out || 'REQUESTS: ' || nreq || '0a'x || 'DOWNLOADS: ' || ndl || '0a'x || 'PUBLISHES: ' || npub || '0a'x || '0a'x
  out = out || 'PER-DAY:' || '0a'x || dayrows || '0a'x
  out = out || 'CLIENTS (kind version os, client-days; * = older than the latest release):' || '0a'x
  none = 1
  do i = 1 to words(ckeys)
    ckey = word(ckeys, i)
    parse var ckey ck '~' cv '~' cos
    star = ' '
    latest = ''
    if IsSafeToken(ck) then latest = ClientLatest(root, ck)
    if latest \= '' & IsSafeVersion(cv) then if CompareVersions(cv, latest) < 0 then star = '*'
    out = out || '  ' || star || left(ck, 10) || left(cv, 10) || left(cos, 12) || right(words(cmarks.ckey), 6) || '0a'x
    none = 0
  end
  if none then out = out || '  (none)' || '0a'x
  out = out || '0a'x || 'TOP DOWNLOADS (package, downloads, client-days):' || '0a'x
  used = ''
  do rank = 1 to 20
    best = ''; bn = -1
    do i = 1 to words(pkeys)
      k = word(pkeys, i)
      if wordpos(k, used) = 0 & pdl.k > bn then do
        best = k; bn = pdl.k
      end
    end
    if best = '' then leave
    used = used best
    out = out || '  ' || left(best, 24) || right(pdl.best, 6) || right(words(pdays.best), 8) || '0a'x
  end
  if used = '' then out = out || '  (none)' || '0a'x
  return out

AdminMain: procedure
  parse arg authdir, a
  parse var a sub p1 p2 rest
  sub = translate(sub)
  if sub = 'ADMIN' then parse var a . sub p1 p2 rest
  sub = translate(sub)
  rest = strip(p2 rest)
  if Sha256Hex('rxpip') = '' then do
    say 'rxpip-admin: no SHA-256 tool (sha256sum / shasum / PowerShell)'
    return 1
  end
  select
    when sub = 'INVITE' then do
      inv = CreateInvite(authdir, strip(p1 rest))
      if inv = '' then do; say 'rxpip-admin: could not create invite'; return 1; end
      say 'invite code (single use, shown once):' inv
      say 'redeem with: rxpip register --user=<name> --invite=' || inv
    end
    when sub = 'ADDUSER' then do
      if \IsSafeUser(p1) then do; say 'rxpip-admin: usage: adduser <name>  (3-32 chars a-z 0-9 _ -)'; return 1; end
      call EnsureDir authdir || '/users'
      if \WriteNew(authdir || '/users/' || p1 || '.user', 'CREATED: ' || date('S') || ' ' || time() || '0a'x) then do
        say "rxpip-admin: user '" || p1 || "' already exists"; return 1
      end
      tok = CreateToken(authdir, p1, 'admin-created')
      if tok = '' then do; say 'rxpip-admin: could not create token'; return 1; end
      say 'user' p1 'created. token (shown once):' tok
    end
    when sub = 'NEWTOKEN' then do
      if \UserExists(authdir, p1) then do; say 'rxpip-admin: no such user'; return 1; end
      lbl = rest; if lbl = '' then lbl = 'admin-created'
      tok = CreateToken(authdir, p1, lbl)
      if tok = '' then do; say 'rxpip-admin: could not create token'; return 1; end
      say 'token for' p1 '(shown once):' tok
    end
    when sub = 'USERS' then do
      u = DirBasesStr(authdir || '/users', '.user')
      say words(u) 'user(s):' u
    end
    when sub = 'TOKENS' then do
      ids = UserTokenIds(authdir, p1)
      do i = 1 to words(ids)
        f = authdir || '/tokens/' || word(ids, i) || '.tok'
        say word(ids, i) FileField(f, 'CREATED') FileField(f, 'LABEL')
      end
      if ids = '' then say '(none)'
    end
    when sub = 'REVOKE' then do      /* revoke <token-id> */
      if \IsHex(p1, 8) then do; say 'rxpip-admin: usage: revoke <8-hex token id>'; return 1; end
      call DelFile authdir || '/tokens/' || p1 || '.tok'
      say 'revoked' p1
    end
    when sub = 'LOCK' then do        /* revoke every token of a user */
      ids = UserTokenIds(authdir, p1)
      do i = 1 to words(ids)
        call DelFile authdir || '/tokens/' || word(ids, i) || '.tok'
      end
      say 'revoked' words(ids) 'token(s) of' p1
    end
    when sub = 'OWNERS' then say p1 || ':' OwnersStr(authdir, p1)
    when sub = 'VISIBILITY' then do  /* visibility <pkg> [public|private] */
      if \IsSafeToken(p1) then do; say 'rxpip-admin: usage: visibility <pkg> [public|private]'; return 1; end
      v = lower(strip(p2))
      if v = 'public' | v = 'private' then call SetVisibility authdir, p1, v
      else if v \= '' then do; say 'rxpip-admin: value must be public or private'; return 1; end
      if IsPrivate(authdir, p1) then say p1 || ': private, readers:' ReadersStr(authdir, p1)
      else say p1 || ': public'
    end
    when sub = 'ADDADMIN' then do
      if \UserExists(authdir, p1) then do; say 'rxpip-admin: no such user'; return 1; end
      if \IsAdmin(authdir, p1) then call WriteAdmins authdir, AdminsStr(authdir) p1
      say 'administrators:' AdminsStr(authdir)
    end
    when sub = 'RMADMIN' then do
      new = ''
      do i = 1 to words(AdminsStr(authdir))
        if word(AdminsStr(authdir), i) \= p1 then new = new word(AdminsStr(authdir), i)
      end
      call WriteAdmins authdir, strip(new)
      say 'administrators:' AdminsStr(authdir)
    end
    when sub = 'ADMINS' then say 'administrators:' AdminsStr(authdir)
    when sub = 'STATS' then do       /* stats [days] */
      root = left(authdir, length(authdir) - length('/.auth'))
      say StatsReport(root, p1)
    end
    when sub = 'SETOWNERS' then do   /* setowners <pkg> <user>...  (recovery) */
      list = rest
      if \IsSafeToken(p1) | list = '' then do; say 'rxpip-admin: usage: setowners <pkg> <user> [<user>...]'; return 1; end
      do i = 1 to words(list)
        if \UserExists(authdir, word(list, i)) then do; say 'rxpip-admin: no such user' word(list, i); return 1; end
      end
      call WriteOwners authdir, p1, list
      say p1 || ':' OwnersStr(authdir, p1)
    end
    otherwise do
      say 'rxpip-admin commands:'
      say '  invite [note]            create a single-use sign-up code'
      say '  adduser <name>           create a user and print its first token'
      say '  newtoken <user> [label]  mint another token for a user'
      say '  users                    list users'
      say '  tokens <user>            list a user''s token ids'
      say '  revoke <token-id>        revoke one token'
      say '  lock <user>              revoke all of a user''s tokens'
      say '  owners <pkg>             show owners'
      say '  visibility <pkg> [public|private]   show / set a package''s visibility'
      say '  setowners <pkg> <u>...   replace the owner list (account recovery)'
      say '  addadmin <user>          make a user an administrator (remote admin + statistics)'
      say '  rmadmin <user>           remove administrator rights'
      say '  admins                   list administrators'
      say '  stats [days]             usage statistics (default 30 days)'
    end
  end
  return 0

CliArgs: procedure
  a = ''
  do i = 1 to arg()
    a = a arg(i)
  end
  return strip(a)

TextHeader: procedure
  say 'Content-Type: text/plain; charset=utf-8'
  say ''
  return

ErrorBody: procedure
  parse arg code, msg
  say 'STATUS: ERROR'
  say 'CODE:' code
  say 'MESSAGE:' msg
  return

/* fetch one value from an a=b&c=d query string, url-decoded */
QGet: procedure
  parse arg qs, wantkey
  wantkey = translate(wantkey)
  do while qs \= ''
    parse var qs pair '&' qs
    if pair = '' then iterate
    parse var pair key '=' val
    key = translate(UrlDecode(key))
    if key = wantkey then return UrlDecode(val)
  end
  return ''

UrlDecode: procedure
  parse arg s
  s = translate(s, ' ', '+')
  out = ''
  do while pos('%', s) > 0
    p = pos('%', s)
    out = out || substr(s, 1, p - 1)
    hex = substr(s, p + 1, 2)
    if datatype(hex, 'X') then out = out || x2c(hex)
    else out = out || '%' || hex
    s = substr(s, p + 3)
  end
  return out || s

IsSafeToken: procedure
  parse arg t
  if t = '' then return 0
  if length(t) > 64 then return 0
  do i = 1 to length(t)
    c = substr(t, i, 1)
    if verify(c, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.') > 0 then return 0
  end
  if pos('..', t) > 0 then return 0
  if left(t,1) = '.' then return 0
  return 1

IsSafeVersion: procedure
  parse arg v
  if \IsSafeToken(v) then return 0
  do i = 1 to length(v)
    if verify(substr(v,i,1), '0123456789.') > 0 then return 0
  end
  return 1

FileExists: procedure
  parse arg fn
  rc = stream(fn, 'c', 'query exists')
  return rc \= ''

FileIsDir: procedure
  parse arg d
  tmp = TempDir() || '/rxpip_isdir_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  if IsWindows() then do
    wd = translate(d, '\', '/')
    'if exist "' || wd || '\" (echo Y) else (echo N)' ' > "' || tmp || '"'
  end
  else do
    '[ -d "' || d || '" ] && echo Y > "' || tmp || '" || echo N > "' || tmp || '"'
  end
  r = ''
  if FileExists(tmp) then do
    r = linein(tmp)
    call stream tmp, 'c', 'close'
  end
  call DelFile tmp
  return strip(r) = 'Y'

/* is this a Windows host? Windows always sets OS=Windows_NT and
   COMSPEC; neither is normally set on Unix/Linux/macOS. Checked once
   via a variable at the top of each helper that needs it, rather than
   assumed, since this script must run unmodified on both. */
IsWindows: procedure
  if translate(value('OS',,'ENVIRONMENT')) = 'WINDOWS_NT' then return 1
  if value('COMSPEC',,'ENVIRONMENT') \= '' then return 1
  return 0

/* a writable scratch directory: $TEMP/$TMP on Windows, /tmp elsewhere */
TempDir: procedure
  if IsWindows() then do
    t = value('TEMP',,'ENVIRONMENT')
    if t = '' then t = value('TMP',,'ENVIRONMENT')
    if t = '' then t = 'C:/Windows/Temp'
    return translate(t, '/', '\')
  end
  return '/tmp'

/* NUL device for discarding stderr in a shelled-out command */
NullSink: procedure
  if IsWindows() then return 'nul'
  return '/dev/null'

DelFile: procedure
  parse arg f
  if IsWindows() then 'del /f /q "' || translate(f,'\','/') || '" >nul 2>nul'
  else 'rm -f "' || f || '"'
  return

DelTree: procedure
  parse arg d
  if IsWindows() then 'rmdir /s /q "' || translate(d,'\','/') || '" >nul 2>nul'
  else 'rm -rf "' || d || '"'
  return

MoveFile: procedure
  parse arg src, dst
  if IsWindows() then 'move /y "' || translate(src,'\','/') || '" "' || translate(dst,'\','/') || '" >nul'
  else 'mv "' || src || '" "' || dst || '"'
  return

EnsureDir: procedure
  parse arg d
  if IsWindows() then 'mkdir "' || translate(d,'\','/') || '" 2>nul'
  else 'mkdir -p "' || d || '"'
  return

IsSafeKind: procedure
  parse arg k
  k = translate(strip(k))
  if k = 'SOURCE' then return 1
  if k = 'BYTECODE' then return 1
  return 0

ArtifactFileName: procedure
  parse arg kind, platform
  return translate(kind) || '-' || translate(platform) || '.rxpkg'

ArtifactPath: procedure
  parse arg root, name, ver, kind, platform
  return root || '/' || name || '/' || ver || '/artifacts/' || ArtifactFileName(kind, platform)

ArtifactsMetaPath: procedure
  parse arg root, name, ver
  return root || '/' || name || '/' || ver || '/ARTIFACTS.META'

/* every artifact record for a version, as KIND|PLATFORM|FILES lines
   ('01'x field sep, '0a'x record sep); '' if none published yet */
ArtifactsStr: procedure
  parse arg root, name, ver
  amf = ArtifactsMetaPath(root, name, ver)
  if \FileExists(amf) then return ''
  out = ''
  curK = ''; curP = ''; curF = ''; have = 0
  do while lines(amf) > 0
    l = linein(amf)
    if l = '' then do
      if have then out = out || curK || '01'x || curP || '01'x || curF || '0a'x
      curK = ''; curP = ''; curF = ''; have = 0
      iterate
    end
    parse var l key ':' val
    key = translate(strip(key))
    val = strip(val)
    if key = 'KIND'     then do; curK = val; have = 1; end
    if key = 'PLATFORM' then curP = val
    if key = 'FILES'    then curF = val
  end
  if have then out = out || curK || '01'x || curP || '01'x || curF || '0a'x
  call stream amf, 'c', 'close'
  return out

/* add or replace (by KIND+PLATFORM) one artifact record */
WriteArtifactRecord: procedure
  parse arg root, name, ver, kind, platform, files
  amf = ArtifactsMetaPath(root, name, ver)
  k. = ''; p. = ''; f. = ''
  cnt = 0
  if FileExists(amf) then do
    curK = ''; curP = ''; curF = ''; have = 0
    do while lines(amf) > 0
      l = linein(amf)
      if l = '' then do
        if have then do
          cnt = cnt + 1
          k.cnt = curK; p.cnt = curP; f.cnt = curF
        end
        curK = ''; curP = ''; curF = ''; have = 0
        iterate
      end
      parse var l key ':' val
      key = translate(strip(key))
      val = strip(val)
      if key = 'KIND'     then do; curK = val; have = 1; end
      if key = 'PLATFORM' then curP = val
      if key = 'FILES'    then curF = val
    end
    if have then do
      cnt = cnt + 1
      k.cnt = curK; p.cnt = curP; f.cnt = curF
    end
    call stream amf, 'c', 'close'
  end
  tmp = amf || '.new'
  replaced = 0
  do i = 1 to cnt
    if translate(k.i) = translate(kind) & translate(p.i) = translate(platform) then do
      call charout tmp, 'KIND: ' || kind || '0a'x
      call charout tmp, 'PLATFORM: ' || platform || '0a'x
      call charout tmp, 'FILES: ' || files || '0a'x
      call charout tmp, '0a'x
      replaced = 1
    end
    else do
      call charout tmp, 'KIND: ' || k.i || '0a'x
      call charout tmp, 'PLATFORM: ' || p.i || '0a'x
      call charout tmp, 'FILES: ' || f.i || '0a'x
      call charout tmp, '0a'x
    end
  end
  if \replaced then do
    call charout tmp, 'KIND: ' || kind || '0a'x
    call charout tmp, 'PLATFORM: ' || platform || '0a'x
    call charout tmp, 'FILES: ' || files || '0a'x
    call charout tmp, '0a'x
  end
  call stream tmp, 'c', 'close'
  call MoveFile tmp, amf
  return

MetaPath: procedure
  parse arg root, name, ver
  return root || '/' || name || '/' || ver || '/PACKAGE.META'

/* raw directory listing (bare names, one per line), OS-appropriate */
ListDirNames: procedure
  parse arg dir, tmp
  if IsWindows() then 'dir /b "' || translate(dir,'\','/') || '" 2>nul >"' || tmp || '"'
  else 'ls -1 "' || dir || '" 2>/dev/null >"' || tmp || '"'
  return

/* space-separated list of package (sub-directory) names under root */
PackageNamesStr: procedure
  parse arg root
  call EnsureDir root
  tmp = TempDir() || '/rxpip_ls_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  call ListDirNames root, tmp
  out = ''
  do while lines(tmp) > 0
    l = strip(linein(tmp))
    if l = '' then iterate
    if left(l,1) = '.' then iterate
    if \FileIsDir(root || '/' || l) then iterate
    out = out || l || ' '
  end
  call stream tmp, 'c', 'close'
  call DelFile tmp
  return strip(out)

/* space-separated, ascending-sorted (dotted numeric) list of versions */
VersionsStr: procedure
  parse arg root, name
  pdir = root || '/' || name
  tmp = TempDir() || '/rxpip_lsv_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  call ListDirNames pdir, tmp
  raw. = ''
  cnt = 0
  do while lines(tmp) > 0
    l = strip(linein(tmp))
    if l = '' then iterate
    cnt = cnt + 1
    raw.cnt = l
  end
  call stream tmp, 'c', 'close'
  call DelFile tmp
  /* insertion sort, local to this procedure -- no cross-frame stems */
  do i = 2 to cnt
    key = raw.i
    j = i - 1
    do while j >= 1
      if CompareVersions(raw.j, key) > 0 then do
        raw.(j+1) = raw.j
        j = j - 1
      end
      else leave
    end
    raw.(j+1) = key
  end
  out = ''
  do i = 1 to cnt
    out = out || raw.i || ' '
  end
  return strip(out)

/* -1, 0, 1 comparing dotted-numeric version strings */
CompareVersions: procedure
  parse arg a, b
  do while a \= '' | b \= ''
    parse var a  ai '.' a
    parse var b  bi '.' b
    if ai = '' then ai = 0
    if bi = '' then bi = 0
    if ai + 0 < bi + 0 then return -1
    if ai + 0 > bi + 0 then return 1
  end
  return 0

LatestVersionOf: procedure
  parse arg root, name
  vs = VersionsStr(root, name)
  if vs = '' then return ''
  return word(vs, words(vs))

/* returns NAME|VERSION|AUTHOR|SUMMARY|REQUIRES using '01'x seps,
   or '' if the package/version does not exist. File lists live per
   ARTIFACT now (see ArtifactsStr), not in this package-level record. */
MetaStr: procedure
  parse arg root, name, ver
  mf = MetaPath(root, name, ver)
  fNAME = ''; fVERSION = ''; fAUTHOR = ''
  fSUMMARY = ''; fREQUIRES = ''
  if \FileExists(mf) then return ''
  do while lines(mf) > 0
    l = linein(mf)
    parse var l key ':' val
    key = translate(strip(key))
    val = strip(val)
    if key = 'NAME'     then fNAME = val
    if key = 'VERSION'  then fVERSION = val
    if key = 'AUTHOR'   then fAUTHOR = val
    if key = 'SUMMARY'  then fSUMMARY = val
    if key = 'REQUIRES' then fREQUIRES = val
  end
  call stream mf, 'c', 'close'
  return fNAME || '01'x || fVERSION || '01'x || fAUTHOR || '01'x || fSUMMARY || '01'x || fREQUIRES

EmitStanza: procedure
  parse arg ms
  if ms = '' then return
  parse var ms fname '01'x fver '01'x fauth '01'x fsum '01'x freq
  say 'NAME:' fname
  say 'VERSION:' fver
  say 'AUTHOR:' fauth
  say 'SUMMARY:' fsum
  say 'REQUIRES:' freq
  say ''
  return

RexxVersionShort: procedure
  parse version v
  return v

Bomb:
  say 'Content-Type: text/plain'
  say ''
  say 'STATUS: ERROR'
  say 'CODE: SERVER_EXCEPTION'
  say 'MESSAGE: internal error at line' sigl':' errortext(rc)
  exit 1
