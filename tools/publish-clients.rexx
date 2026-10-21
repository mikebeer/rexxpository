/* publish-clients.rexx -- sign and publish the rxpip client releases
 *
 *   regina -a tools/publish-clients.rexx [--min=1.0.0] [kind ...]
 *
 * Works on Windows, Linux and macOS. Run it from a checkout, logged in as
 * an rxpip administrator. For each kind (regina oorexx netrexx crexx) it
 * reads the version from the client source (ClientVersion), stages the
 * release files, signs them with minisign (ONE password prompt per kind)
 * and publishes them with `admin client-publish`.
 *
 * Environment:  NOSIGN=1        publish unsigned
 *               MINISIGN_KEY    secret key file (default: minisign's own)
 *               RXPIP           command that runs the client (default: the
 *                               client of this checkout, run by Regina)
 */
win = (translate(value('OS', , 'ENVIRONMENT')) = 'WINDOWS_NT')

parse source . . me
me = translate(me, '/', '\')
tools = left(me, max(lastpos('/', me) - 1, 0))
if tools = '' then tools = '.'
old = directory()
root = translate(directory(tools || '/..'), '/', '\')
call directory old

min = ''
kinds = ''
do i = 1 to arg()
  a = arg(i)
  if left(a, 6) = '--min=' then min = ' ' || a
  else kinds = kinds a
end
kinds = strip(kinds)
if kinds = '' then kinds = 'regina oorexx netrexx crexx'

rxpip = value('RXPIP', , 'ENVIRONMENT')
if rxpip = '' then rxpip = 'regina -a ' || Q(root || '/client/rxpip.rexx')
nosign = (value('NOSIGN', , 'ENVIRONMENT') \= '')
keyarg = ''
if value('MINISIGN_KEY', , 'ENVIRONMENT') \= '' then keyarg = ' -s ' || Q(value('MINISIGN_KEY', , 'ENVIRONMENT'))

if \nosign then do
  if win then 'minisign -v >nul 2>nul'
  else 'minisign -v >/dev/null 2>&1'
  if rc \= 0 then do
    say 'minisign was not found on the PATH. Install it, or set NOSIGN=1 to publish unsigned.'
    exit 1
  end
end

tmp = value('TEMP', , 'ENVIRONMENT')
if tmp = '' then tmp = value('TMP', , 'ENVIRONMENT')
if tmp = '' then tmp = '/tmp'
tmp = translate(tmp, '/', '\')

bad = 0
do k = 1 to words(kinds)
  kind = word(kinds, k)
  src. = ''
  select
    when kind = 'regina'  then files = 'client/rxpip.rexx client/rxpip.bat'
    when kind = 'oorexx'  then files = 'client/rxpip.rexx client/oorexx/rxpip-oorexx client/oorexx/rxpip-oorexx.bat'
    when kind = 'netrexx' then files = 'client/netrexx/Rxpip.nrx client/netrexx/rxpip-netrexx client/netrexx/rxpip-netrexx.bat'
    when kind = 'crexx'   then files = 'client/crexx/rxpip.crexx client/crexx/rxpip-crexx client/crexx/rxpip-crexx.bat'
    otherwise do
      say 'unknown kind' kind
      bad = 1
      iterate
    end
  end
  version = VersionOf(root || '/' || word(files, 1))
  if version = '' then do
    say kind': cannot read the version from' word(files, 1)
    bad = 1
    iterate
  end
  say
  say '==' kind version

  stage = tmp || '/rxpip_rel_' || kind
  if win then 'if exist ' || Q(stage) || ' rmdir /s /q ' || Q(stage) || ' >nul 2>nul'
  else 'rm -rf ' || Q(stage)
  if win then 'mkdir ' || Q(stage)
  else 'mkdir -p ' || Q(stage)
  names = ''
  ok = 1
  do f = 1 to words(files)
    path = root || '/' || word(files, f)
    base = substr(word(files, f), lastpos('/', word(files, f)) + 1)
    if win then 'copy /y ' || Q(path) || ' ' || Q(stage || '/' || base) || ' >nul'
    else 'cp ' || Q(path) || ' ' || Q(stage || '/' || base)
    if rc \= 0 then do
      say 'cannot copy' path
      ok = 0
    end
    names = names base
  end
  if \ok then do
    bad = 1
    iterate
  end

  call directory stage
  list = ''
  pub = ''
  do f = 1 to words(names)
    list = list || ' ' || Q(word(names, f))
    pub = pub || ' ' || Q(word(names, f))
    if \nosign then pub = pub || ' ' || Q(word(names, f) || '.minisig')
  end
  if \nosign then do
    'minisign -S' || keyarg || ' -m' || list
    if rc \= 0 then do
      say kind': signing failed'
      bad = 1
      call directory old
      iterate
    end
  end
  else say kind': NOT signed (NOSIGN is set)'
  rxpip ' admin client-publish ' || kind || ' --version=' || version || min || pub
  if rc \= 0 then bad = 1
  call directory old
end

say
if bad then say 'Some releases were NOT published (see above).'
else say 'Published:' kinds
exit bad

/* quote a path for the shell */
Q: procedure expose win
  parse arg p
  if win then p = translate(p, '\', '/')
  return '"' || p || '"'

/* the number ClientVersion returns in a client source file */
VersionOf: procedure
  parse arg f
  found = 0
  v = ''
  do while lines(f) > 0 & v = ''
    l = linein(f)
    s = translate(strip(l), 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
    if \found then do
      if left(s, 13) = 'clientversion' | left(s, 20) = 'method clientversion' then found = 1
    end
    else if pos("return '", l) > 0 then parse var l . "return '" v "'" .
  end
  call stream f, 'c', 'close'
  return v
