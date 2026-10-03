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
     action=PING
     action=LIST
     action=SEARCH   &q=<term>
     action=INFO      &name=<pkg>            [&version=<ver>]
     action=VERSIONS  &name=<pkg>
     action=ARTIFACTS &name=<pkg>            [&version=<ver>]
     action=DOWNLOAD  &name=<pkg>            [&version=<ver>]
                       [&kind=<SOURCE|BYTECODE>] [&platform=<tag>]
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

/* ----- read CGI environment -------------------------------------------*/
method_   = value('REQUEST_METHOD',,'ENVIRONMENT')
qstring   = value('QUERY_STRING',,'ENVIRONMENT')
clen      = value('CONTENT_LENGTH',,'ENVIRONMENT')
if clen = '' then clen = 0

action = translate(QGet(qstring, 'ACTION'))

select
  when action = 'PING'     then call Action_Ping
  when action = 'LIST'     then call Action_List     REPO_ROOT
  when action = 'SEARCH'   then call Action_Search    REPO_ROOT, qstring
  when action = 'INFO'     then call Action_Info      REPO_ROOT, qstring
  when action = 'VERSIONS' then call Action_Versions  REPO_ROOT, qstring
  when action = 'ARTIFACTS' then call Action_Artifacts REPO_ROOT, qstring
  when action = 'DOWNLOAD' then call Action_Download  REPO_ROOT, qstring
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
  parse arg root
  call TextHeader
  names = PackageNamesStr(root)
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
  parse arg root, qstring
  call TextHeader
  term = translate(QGet(qstring, 'Q'))
  names = PackageNamesStr(root)
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
  parse arg root, qstring
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
  if ver = '' | \FileExists(MetaPath(root,name,ver)) then do
    call ErrorBody 'NOT_FOUND', "package '" || name || "' not found"
    return
  end
  say 'STATUS: OK'
  say 'COUNT: 1'
  say ''
  call EmitStanza MetaStr(root, name, ver)
  return

Action_Versions:
  parse arg root, qstring
  call TextHeader
  name = QGet(qstring, 'NAME')
  if \IsSafeToken(name) then do
    call ErrorBody 'BAD_NAME', 'invalid package name'
    return
  end
  vs = VersionsStr(root, name)
  say 'STATUS: OK'
  say 'COUNT:' words(vs)
  say ''
  do i = 1 to words(vs)
    say 'VERSION:' word(vs, i)
  end
  return

Action_Artifacts:
  parse arg root, qstring
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
  if ver = '' then do
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
  parse arg root, qstring
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
  if ver = '' | \FileExists(artfile) then do
    call Fail 404, 'NOT_FOUND', "no " || kind || "/" || platform || " artifact for '" || name || "' " || ver
    return
  end
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

  call EnsureDir authdir
  ownerfile = authdir || '/' || name || '.owner'
  claiming = 0
  if FileExists(ownerfile) then do
    if \OwnerMatches(ownerfile, token) then do
      call Fail 403, 'FORBIDDEN', "token does not match the owner of '" || name || "'"
      return
    end
  end
  else claiming = 1

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
  stage = stagedir || '/upload_' || time('L') || '_' || random(1,99999) || '.tmp'
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
    rec = MakeSecretRecord(token)
    if rec = '' then do
      call DelFile stage
      call Fail 500, 'SERVER_NO_RANDOM', 'server could not obtain secure random bytes to salt the token'
      return
    end
    if \WriteNew(ownerfile, rec) then do
      /* lost a race with a concurrent first publish of the same name */
      if \OwnerMatches(ownerfile, token) then do
        call DelFile stage
        call Fail 403, 'FORBIDDEN', "'" || name || "' was claimed by someone else just now"
        return
      end
    end
  end

  call EnsureDir root || '/' || name || '/' || ver || '/artifacts'
  call MoveFile stage, artfile
  call WriteArtifactRecord root, name, ver, kind, platform, filelist
  note = WriteMetaIfAbsent(root, name, ver, author, summary, requires)

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

OwnerMatches: procedure
  parse arg ownerfile, token
  rec = ''
  if FileExists(ownerfile) then do
    rec = strip(linein(ownerfile))
    call stream ownerfile, 'c', 'close'
  end
  return VerifySecret(token, rec)

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
  tn = TempDir() || '/rxpip_vn_' || time('L') || '_' || random(1,99999) || '.tmp'
  tv = TempDir() || '/rxpip_vv_' || time('L') || '_' || random(1,99999) || '.tmp'
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
  tmp = TempDir() || '/rxpip_isdir_' || time('L') || '_' || random(1,99999) || '.tmp'
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
  tmp = TempDir() || '/rxpip_ls_' || time('L') || '_' || random(1,99999) || '.tmp'
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
  tmp = TempDir() || '/rxpip_lsv_' || time('L') || '_' || random(1,99999) || '.tmp'
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
