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
  when action = 'PUBLISH'  then call Action_Publish   REPO_ROOT, AUTH_DIR, method_, clen
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
    call TextHeader
    call ErrorBody 'BAD_NAME', 'invalid package name'
    return
  end
  ver = QGet(qstring, 'VERSION')
  if ver = '' then ver = LatestVersionOf(root, name)
  kind = QGet(qstring, 'KIND')
  if kind = '' then kind = 'SOURCE'
  platform = QGet(qstring, 'PLATFORM')
  if platform = '' then platform = 'any'
  if \IsSafeKind(kind) | \IsSafeToken(platform) then do
    call TextHeader
    call ErrorBody 'BAD_ARTIFACT', 'invalid kind/platform'
    return
  end
  artfile = ArtifactPath(root, name, ver, kind, platform)
  if ver = '' | \FileExists(artfile) then do
    call TextHeader
    call ErrorBody 'NOT_FOUND', "no " || kind || "/" || platform || " artifact for '" || name || "' " || ver
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

Action_Publish:
  parse arg root, authdir, method_, clen
  call TextHeader
  if translate(method_) \= 'POST' then do
    call ErrorBody 'METHOD_NOT_ALLOWED', 'publish requires POST'
    return
  end
  /* Metadata normally arrives via X-Rxpip-* request headers (which
     Apache/mod_cgi forwards as HTTP_X_RXPIP_* env vars per the CGI
     spec). As a fallback -- useful behind proxies or minimal CGI
     handlers that don't forward custom headers -- the same fields
     may be supplied on the query string instead; headers win if both
     are present. */
  qstring  = value('QUERY_STRING',,'ENVIRONMENT')
  name     = value('HTTP_X_RXPIP_NAME',,'ENVIRONMENT')
  if name = '' then name = QGet(qstring, 'NAME')
  ver      = value('HTTP_X_RXPIP_VERSION',,'ENVIRONMENT')
  if ver = '' then ver = QGet(qstring, 'VERSION')
  author   = value('HTTP_X_RXPIP_AUTHOR',,'ENVIRONMENT')
  if author = '' then author = QGet(qstring, 'AUTHOR')
  summary  = value('HTTP_X_RXPIP_SUMMARY',,'ENVIRONMENT')
  if summary = '' then summary = QGet(qstring, 'SUMMARY')
  requires = value('HTTP_X_RXPIP_REQUIRES',,'ENVIRONMENT')
  if requires = '' then requires = QGet(qstring, 'REQUIRES')
  kind     = value('HTTP_X_RXPIP_KIND',,'ENVIRONMENT')
  if kind = '' then kind = QGet(qstring, 'KIND')
  if kind = '' then kind = 'SOURCE'
  platform = value('HTTP_X_RXPIP_PLATFORM',,'ENVIRONMENT')
  if platform = '' then platform = QGet(qstring, 'PLATFORM')
  if platform = '' then platform = 'any'
  token    = value('HTTP_X_RXPIP_TOKEN',,'ENVIRONMENT')
  if token = '' then token = QGet(qstring, 'TOKEN')

  if \IsSafeToken(name) then do
    call ErrorBody 'BAD_NAME', 'invalid or missing package name'
    return
  end
  if \IsSafeVersion(ver) then do
    call ErrorBody 'BAD_VERSION', 'invalid/missing version (expected dotted numeric, e.g. 1.2.0)'
    return
  end
  if \IsSafeKind(kind) then do
    call ErrorBody 'BAD_KIND', 'kind must be SOURCE or BYTECODE'
    return
  end
  if \IsSafeToken(platform) then do
    call ErrorBody 'BAD_PLATFORM', 'invalid platform tag'
    return
  end
  if token = '' then do
    call ErrorBody 'NO_TOKEN', 'publish requires X-Rxpip-Token header'
    return
  end
  if clen = 0 | clen = '' then do
    call ErrorBody 'EMPTY_BODY', 'no package data received'
    return
  end

  call EnsureDir authdir
  ownerfile = authdir || '/' || name || '.owner'
  if FileExists(ownerfile) then do
    owned = linein(ownerfile)
    call stream ownerfile, 'c', 'close'
    if owned \= token then do
      call ErrorBody 'FORBIDDEN', "token does not match existing owner of '" || name || "'"
      return
    end
  end
  else do
    call charout ownerfile, token
    call stream ownerfile, 'c', 'close'
  end

  artdir = root || '/' || name || '/' || ver || '/artifacts'
  call EnsureDir artdir
  artfile = ArtifactPath(root, name, ver, kind, platform)

  data = charin(, , clen)
  call charout artfile, data
  call stream artfile, 'c', 'close'

  filelist = ListTarContents(artfile)
  call WriteArtifactRecord root, name, ver, kind, platform, filelist

  metafile = MetaPath(root, name, ver)
  call charout metafile, 'NAME:' name || '0a'x
  call charout metafile, 'VERSION:' ver || '0a'x
  call charout metafile, 'AUTHOR:' author || '0a'x
  call charout metafile, 'SUMMARY:' summary || '0a'x
  call charout metafile, 'REQUIRES:' requires || '0a'x
  call stream metafile, 'c', 'close'

  say 'STATUS: OK'
  say 'NAME:' name
  say 'VERSION:' ver
  say 'KIND:' kind
  say 'PLATFORM:' platform
  say 'MESSAGE: published'
  return

/* =======================================================================
   HELPERS  (all self-contained -- return plain strings, no shared stems)
   ======================================================================= */

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
    if l = '.auth' then iterate
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

ListTarContents: procedure
  /* tar itself: Windows 10 1803+ / Server 2019+ ships a bsdtar-
     compatible tar.exe in System32 that accepts the same tzf/czf/xzf
     syntax as Unix tar, so this command line is unchanged across
     platforms -- only the null-device name for discarding stderr
     differs. On an older Windows host without tar.exe on PATH, install
     one (e.g. via bsdtar or Git for Windows) and this still works. */
  parse arg pkgfile
  tmp = TempDir() || '/rxpip_tar_' || time('L') || '_' || random(1,99999) || '.tmp'
  'tar tzf "' || pkgfile || '" 2>' || NullSink() || ' >"' || tmp || '"'
  out = ''
  do while lines(tmp) > 0
    l = strip(linein(tmp))
    if l = '' then iterate
    if right(l,1) = '/' then iterate
    out = out || l || ' '
  end
  call stream tmp, 'c', 'close'
  call DelFile tmp
  return strip(out)

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
