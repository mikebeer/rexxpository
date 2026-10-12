#!/usr/bin/regina -a
/* ---------------------------------------------------------------------
   RXPIP  --  the REXX package manager (Regina client)
   ---------------------------------------------------------------------
   Usage:
     rxpip install <name>[==<version>]
     rxpip uninstall <name>
     rxpip list
     rxpip search <term>
     rxpip show <name>
     rxpip freeze
     rxpip scan <file.rexx>
     rxpip run <file.rexx> [args...]
     rxpip build <file.rexx> [-o output.rexx]
     rxpip publish <file.rxpkg> --name=X --version=Y [--author=A]
                    [--summary=S] [--requires=R]
                    [--kind=SOURCE|BYTECODE] [--platform=TAG] --token=T
     rxpip config [get <key> | set <key> <value>]
     rxpip help

   Transport: shells out to `curl`; no REXX-native HTTPS stack is
   assumed, so this works unmodified on any Regina build.

   Argument handling: run under `regina -a` (see shebang above) so each
   command-line argument arrives as its own ARG(n) element rather than
   REXX's default of joining the whole command line into one string --
   the default loses word boundaries inside a quoted value such as
   --summary="a description with spaces". Internally the arguments are
   rejoined with '01'x (a byte that can't appear in a shell argument)
   so the rest of this script can still work with plain delimited
   strings while preserving each original argument intact.

   Local state lives under $RXPIP_HOME (default ~/.rxpip):
     config.txt      REPO_URL / LIB_DIR / INTERPRETER settings
     installed.txt   stanza records of installed packages
     lib/            flattened *.rexx files from installed packages
     cache/          downloaded .rxpkg archives, kept for offline reuse

   IMPORTANT -- how /* REQUIRE */ actually gets your code to run:
   Classic REXX interpreters (Regina included) do NOT auto-discover
   external routines by scanning the current directory for a file
   matching the routine's name -- that filename=routine convention is
   NOT part of the language on these interpreters. The only fully
   portable way to make an installed package's routines callable is
   to bring their source text into the SAME compiled program as the
   caller. `rxpip run` and `rxpip build` do this by concatenating:
     1. your script's source
     2. a safety EXIT (so execution can never fall through into the
        appended library code)
     3. the source of every installed package file
   into one temporary (run) or permanent (build) .rexx file, which is
   then a completely ordinary, self-contained REXX program: every
   /* REQUIRE */-d routine is now just another internal label in the
   same file. `rxpip install`/`scan` alone only fetch files into
   lib/ -- use `run` or `build` to actually execute REQUIRE-based code.
   --------------------------------------------------------------------- */

signal on syntax name Bomb
signal on novalue name Bomb

/* rebuild the argument list, one true ARG(n) element per '01'x-
   delimited token, so no downstream parsing has to re-guess word
   boundaries that the shell already resolved for us */
allargs = ''
do i = 1 to arg()
  allargs = allargs || arg(i) || '01'x
end

home = value('RXPIP_HOME',,'ENVIRONMENT')
if home = '' then do
  h = value('HOME',,'ENVIRONMENT')
  if h = '' then h = value('USERPROFILE',,'ENVIRONMENT')  /* Windows has no HOME by default */
  home = translate(h, '/', '\') || '/.rxpip'
end
call EnsureDir home
call EnsureDir home || '/lib'
call EnsureDir home || '/cache'
call LoadOrInitConfig home

parse var allargs cmd '01'x rest
cmd = translate(cmd)

select
  when cmd = 'INSTALL'   then call CmdInstall rest
  when cmd = 'UNINSTALL' then call CmdUninstall rest
  when cmd = 'LIST'      then call CmdList
  when cmd = 'SEARCH'    then call CmdSearch rest
  when cmd = 'SHOW'      then call CmdShow rest
  when cmd = 'FREEZE'    then call CmdFreeze
  when cmd = 'SCAN'      then call CmdScan rest
  when cmd = 'RUN'       then call CmdRun rest
  when cmd = 'BUILD'     then call CmdBuild rest
  when cmd = 'PUBLISH'   then call CmdPublish rest
  when cmd = 'CONFIG'    then call CmdConfig rest
  when cmd = 'REGISTER'  then call CmdRegister rest
  when cmd = 'LOGIN'     then call CmdLogin rest
  when cmd = 'LOGOUT'    then call CmdLogout
  when cmd = 'WHOAMI'    then call CmdWhoami
  when cmd = 'TOKEN'     then call CmdToken rest
  when cmd = 'OWNER'     then call CmdOwner rest
  when cmd = 'HELP'      then call CmdHelp
  when cmd = ''          then call CmdHelp
  otherwise do
    say "rxpip: unknown command '" || cmd || "' -- try 'rxpip help'"
    exit 1
  end
end
exit 0

/* =======================================================================
   COMMANDS
   ======================================================================= */

CmdHelp:
  say 'RXPIP -- the REXX package manager'
  say ''
  say 'Commands:'
  say '  install <name>[==version]   install a package (and its deps)'
  say '  uninstall <name>            remove an installed package'
  say '  list                        list installed packages'
  say '  search <term>               search the repository'
  say '  show <name>                 show repository details for a package'
  say '  freeze                      print installed packages as name==version'
  say '  scan <file.rexx>            install packages named in /* REQUIRE */'
  say '  run <file.rexx> [args]      scan + auto-install, merge, then execute'
  say '  build <file.rexx> [--output=out]  scan + auto-install, write merged standalone .rexx'
  say '  publish <pkgfile> --name=N --version=V [...]   upload a package (needs login)'
  say '  register --user=U --invite=CODE   create an account (invite-only); saves your token'
  say '  login [--token=T]           save a token (or read it from env RXPIP_TOKEN)'
  say '  logout | whoami             forget / show the saved login'
  say '  token new [--label=L] | list | revoke <id>   manage your API tokens'
  say '  owner list|add|remove <pkg> [user]   manage who may publish a package'
  say '  config get|set <key> [val]  view/change REPO_URL, LIB_DIR, INTERPRETER'
  say '  help                        this message'
  return

CmdInstall: procedure expose home cfg.
  parse arg spec '01'x .
  spec = strip(spec)
  if spec = '' then do
    say 'usage: rxpip install <name>[==version]'
    exit 1
    return
  end
  seen = ''
  call InstallOne spec, seen
  return

/* recursive install with a simple "already processed" guard (space list) */
InstallOne: procedure expose home cfg.
  parse arg spec, seen
  /* spec is "name", "name==exact" or "name>=minimum" */
  minver = ''
  if pos('>=', spec) > 0 then do
    parse var spec name '>=' minver
    wantver = ''
  end
  else parse var spec name '==' wantver
  name = strip(name)
  wantver = strip(wantver)
  minver = strip(minver)
  if minver \= '' then wantver = ''

  if wordpos(name, seen) > 0 then return seen  /* cycle guard */
  seen = seen name

  curver = InstalledVersion(home, name)
  if curver \= '' then do
    if (wantver = '' & minver = '') | (wantver \= '' & CompareVersions(curver, wantver) >= 0) | ,
       (minver \= '' & CompareVersions(curver, minver) >= 0) then do
      say 'rxpip: ' || name || ' ' || curver || ' already installed'
      /* still walk its dependencies -- they may have been individually
         uninstalled since, and "already installed" must not mean
         "assume its whole dependency tree is still intact" */
      rec = FindInstalledRecord(home, name)
      reqs = translate(StanzaFieldPlain(rec, 'REQUIRES'), ' ', ',')
      do i = 1 to words(reqs)
        tok = word(reqs, i)
        if tok = '' then iterate
        depname = tok
        depver  = ''
        if pos('>=', tok) > 0 then parse var tok depname '>=' depver
        depspec = depname
        if depver \= '' then depspec = depname || '>=' || depver
        seen = InstallOne(depspec, seen)
      end
      return seen
    end
  end

  info = ServerGet(cfg.REPO_URL, 'INFO', 'name=' || UrlEncode(name) || WithVer(wantver))
  if StanzaField(info,'STATUS') \= 'OK' then do
    say "rxpip: cannot resolve '" || name || "': " || InfoMessage(info)
    return seen
  end
  ver      = StanzaField(info, 'VERSION')
  if minver \= '' & CompareVersions(ver, minver) < 0 then do
    say "rxpip: '" || name || "' needs version >=" || minver || ' but the repository has only' ver
    return seen
  end
  author   = StanzaField(info, 'AUTHOR')
  summary  = StanzaField(info, 'SUMMARY')
  requires = StanzaField(info, 'REQUIRES')

  /* Ask the server which artifacts exist for this version, then pick
     the best one for this machine: an exact BYTECODE match for our
     platform tag if one has been published, else the universal
     SOURCE/any artifact (see server's artifact-model note). */
  artresp = ServerGet(cfg.REPO_URL, 'ARTIFACTS', 'name=' || UrlEncode(name) || '&version=' || UrlEncode(ver))
  chosen = SelectBestArtifact(artresp, PlatformTag())
  if chosen = '' then do
    say "rxpip: no compatible artifact for '" || name || "' " || ver || ' (need SOURCE/any or a match for ' || PlatformTag() || ')'
    return seen
  end
  parse var chosen kind '01'x platform '01'x files

  say 'rxpip: installing' name ver '(' || kind || '/' || platform || ') ...'

  cachefile = home || '/cache/' || name || '-' || ver || '-' || kind || '-' || platform || '.rxpkg'
  rc = ServerDownload(cfg.REPO_URL, name, ver, kind, platform, cachefile)
  if rc \= 0 then do
    say 'rxpip: download failed for' name ver
    return seen
  end

  pkgdir = home || '/pkgs/' || name || '/' || ver
  call EnsureDir pkgdir
  'tar xzf "' || cachefile || '" -C "' || pkgdir || '" 2>' || NullSink()

  /* flatten: copy every *.rexx file into the shared lib/ dir so that
     unqualified CALLs resolve for `rxpip run` */
  call EnsureDir home || '/lib'
  do i = 1 to words(files)
    fn = word(files, i)
    call CopyFile pkgdir || '/' || fn, home || '/lib/' || fn
  end

  call RecordInstalled home, name, ver, author, summary, requires, files

  /* recurse into dependencies: space or comma separated "name" or
     "name>=version" tokens */
  reqs = translate(requires, ' ', ',')
  do i = 1 to words(reqs)
    tok = word(reqs, i)
    if tok = '' then iterate
    depname = tok
    depver  = ''
    if pos('>=', tok) > 0 then parse var tok depname '>=' depver
    depspec = depname
    if depver \= '' then depspec = depname || '>=' || depver
    seen = InstallOne(depspec, seen)
  end
  return seen

CmdUninstall: procedure expose home
  parse arg name '01'x .
  name = strip(name)
  if name = '' then do
    say 'usage: rxpip uninstall <name>'
    exit 1
    return
  end
  rec = FindInstalledRecord(home, name)
  if rec = '' then do
    say "rxpip: '" || name || "' is not installed"
    exit 1
    return
  end
  files = StanzaFieldPlain(rec, 'FILES')
  do i = 1 to words(files)
    fn = word(files, i)
    call DelFile home || '/lib/' || fn
  end
  call DelTree home || '/pkgs/' || name
  call RemoveInstalledRecord home, name
  say 'rxpip: removed' name
  return

CmdList: procedure expose home
  idx = home || '/installed.txt'
  if \FileExists(idx) then do
    say '(no packages installed)'
    return
  end
  say left('NAME',20) left('VERSION',12) 'SUMMARY'
  say copies('-', 60)
  do while lines(idx) > 0
    l = linein(idx)
    if left(l,5) = 'NAME:' then do
      nm = strip(substr(l,6))
      vl = linein(idx)
      ver = strip(substr(vl,9))
      al  = linein(idx)
      sl  = linein(idx)
      sm  = strip(substr(sl,9))
      rl  = linein(idx)
      fl  = linein(idx)
      bl  = linein(idx)
      say left(nm,20) left(ver,12) sm
    end
  end
  call stream idx, 'c', 'close'
  return

CmdSearch: procedure expose cfg.
  parse arg rest
  /* rejoin every word/argument the user typed into one natural search
     phrase, regardless of how many separate shell words it was */
  term = ''
  do while rest \= ''
    parse var rest one '01'x rest
    if one = '' then iterate
    if term = '' then term = one
    else term = term || ' ' || one
  end
  resp = ServerGet(cfg.REPO_URL, 'SEARCH', 'q=' || UrlEncode(term))
  call PrintStanzas resp
  return

CmdShow: procedure expose cfg.
  parse arg name '01'x .
  name = strip(name)
  if name = '' then do
    say 'usage: rxpip show <name>'
    exit 1
    return
  end
  resp = ServerGet(cfg.REPO_URL, 'INFO', 'name=' || UrlEncode(name))
  if StanzaField(resp,'STATUS') \= 'OK' then do
    say 'rxpip:' InfoMessage(resp)
    exit 1
    return
  end
  call PrintStanzas resp
  return

CmdFreeze: procedure expose home
  idx = home || '/installed.txt'
  if \FileExists(idx) then return
  do while lines(idx) > 0
    l = linein(idx)
    if left(l,5) = 'NAME:' then nm = strip(substr(l,6))
    if left(l,8) = 'VERSION:' then do
      ver = strip(substr(l,9))
      say nm || '==' || ver
    end
  end
  call stream idx, 'c', 'close'
  return

CmdScan: procedure expose home cfg.
  parse arg fn '01'x .
  fn = strip(fn)
  if fn = '' | \FileExists(fn) then do
    say "rxpip: file not found: '" || fn || "'"
    exit 1
    return
  end
  reqs = ScanRequires(fn)
  if reqs = '' then do
    say 'rxpip: no /* REQUIRE ... */ directives found in' fn
    return
  end
  seen = ''
  do i = 1 to words(reqs)
    seen = InstallOne(word(reqs,i), seen)
  end
  return

/* parse /* REQUIRE name[>=ver] */ ... *\/ directives out of a rexx file,
   return space-separated list of "name" or "name==version" specs */
ScanRequires: procedure
  parse arg fn
  out = ''
  do while lines(fn) > 0
    l = strip(linein(fn))
    if left(l,2) \= '/*' then iterate
    if pos('REQUIRE', translate(l)) = 0 then iterate
    /* strip comment markers */
    body = l
    p = pos('/*', body)
    if p > 0 then body = substr(body, p+2)
    p = pos('*/', body)
    if p > 0 then body = substr(body, 1, p-1)
    body = strip(body)
    /* body now like: REQUIRE mathutils   or  REQUIRE strutils>=1.0 */
    up = translate(body)
    if left(up,7) \= 'REQUIRE' then iterate
    pkgspec = strip(substr(body, 8))
    if pkgspec = '' then iterate
    if pos('>=', pkgspec) > 0 then do
      parse var pkgspec pn '>=' pv
      out = out || strip(pn) || '>=' || strip(pv) || ' '
    end
    else out = out || pkgspec || ' '
  end
  call stream fn, 'c', 'close'
  return strip(out)

CmdRun: procedure expose home cfg.
  parse arg fn '01'x argrest
  fn = strip(fn)
  /* remaining tokens get forwarded to the target script's own ARG();
     each is shell-quoted individually so a value with embedded spaces
     survives the trip through the 'cd ... && interp ...' command line
     below intact, instead of being re-split by the shell. */
  passthru = ''
  do while argrest \= ''
    parse var argrest one '01'x argrest
    if one = '' then iterate
    passthru = passthru || ' ' || ShellQuote(one)
  end
  if fn = '' | \FileExists(fn) then do
    say "rxpip: file not found: '" || fn || "'"
    exit 1
  end
  reqs = ScanRequires(fn)
  seen = ''
  do i = 1 to words(reqs)
    seen = InstallOne(word(reqs,i), seen)
  end

  merged = home || '/run_' || time('L') || '_' || random(1,99999) || '.rexx'
  call MergeScript fn, home, merged

  interp = cfg.INTERPRETER
  if interp = '' then interp = 'regina'

  runrc = RunInDir(Dirname(merged), interp || ' -a "./' || Basename(merged) || '"' || passthru)
  call DelFile merged
  exit runrc

CmdBuild: procedure expose home
  parse arg args
  parse var args fn '01'x .
  if fn = '' | \FileExists(fn) then do
    say 'usage: rxpip build <file.rexx> [--output=output.rexx]'
    exit 1
  end
  outfile = OptValue(args, 'output')
  if outfile = '' then outfile = 'build_' || Basename(fn)

  reqs = ScanRequires(fn)
  seen = ''
  do i = 1 to words(reqs)
    seen = InstallOne(word(reqs,i), seen)
  end

  call MergeScript fn, home, outfile
  say 'rxpip: wrote self-contained program to' outfile
  return

/* build a self-contained REXX program: original source + safety EXIT +
   every currently-installed package file, concatenated via the shell
   (keeps this fast and simple regardless of file sizes). Unix uses
   cat/echo in a subshell whose combined output is redirected; Windows
   uses the equivalent TYPE/ECHO sequence with '&' (unconditional-next,
   unlike '&&') so an empty lib/ directory doesn't abort the sequence
   on either platform. */
MergeScript: procedure
  parse arg srcfile, home, outfile
  if IsWindows() then do
    wsrc = translate(srcfile,'\','/')
    wlib = translate(home,'\','/') || '\lib\*.rexx'
    wout = translate(outfile,'\','/')
    '(type "' || wsrc || '" & echo. & echo exit & type "' || wlib || '" 2>nul) > "' || wout || '"'
  end
  else do
    '(cat "' || srcfile || '"; echo; echo "exit"; cat "' || home || '/lib/"*.rexx 2>/dev/null) > "' || outfile || '"'
  end
  return

CmdPublish: procedure expose home
  parse arg args
  parse var args pkgfile '01'x .
  if pkgfile = '' | \FileExists(pkgfile) then do
    say 'usage: rxpip publish <file.rxpkg> --name=X --version=Y [--token=T]' ,
        '[--author=A --summary=S --requires=R --kind=SOURCE|BYTECODE --platform=TAG]'
    exit 1
    return
  end
  name = OptValue(args, 'name')
  ver  = OptValue(args, 'version')
  author = OptValue(args, 'author')
  summary = OptValue(args, 'summary')
  requires = OptValue(args, 'requires')
  kind = OptValue(args, 'kind')
  if kind = '' then kind = 'SOURCE'
  platform = OptValue(args, 'platform')
  if platform = '' then platform = 'any'
  cfg.REPO_URL = GetConfigValue(home, 'REPO_URL')
  token = ResolveToken(home, cfg.REPO_URL, args)
  if name = '' | ver = '' | token = '' then do
    say 'rxpip: --name, --version and a login are required (rxpip login, or --token=T, or env RXPIP_TOKEN)'
    exit 1
    return
  end
  if \TokenLooksValid(token) then do
    say 'rxpip: token must be 16-128 characters from A-Z a-z 0-9 . _ ~ -'
    exit 1
    return
  end
  rc = ServerPublish(cfg.REPO_URL, pkgfile, name, ver, author, summary, requires, kind, platform, token)
  exit rc
  return

/* ---- accounts, tokens, owners ---- */

/* token to use: --token=, then env RXPIP_TOKEN, then the saved login */
ResolveToken: procedure
  parse arg home, repo, args
  t = OptValue(args, 'token')
  if t = '' then t = value('RXPIP_TOKEN',,'ENVIRONMENT')
  if t = '' then do
    parse value GetCredential(home, repo) with u '01'x t
  end
  return t

TokenLooksValid: procedure
  parse arg t
  if length(t) < 16 | length(t) > 128 then return 0
  return verify(t, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~-') = 0

/* credentials.txt: one line per repository:  <repo_url> <user> <token>
   (kept private to the user on Unix: mode 600) */
GetCredential: procedure
  parse arg home, repo
  f = home || '/credentials.txt'
  res = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = linein(f)
      parse var l r u t .
      if r = repo then res = u || '01'x || t
    end
    call stream f, 'c', 'close'
  end
  return res

SaveCredential: procedure
  parse arg home, repo, user, token
  f = home || '/credentials.txt'
  keep = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = linein(f)
      parse var l r .
      if r \= repo & strip(l) \= '' then keep = keep || l || '0a'x
    end
    call stream f, 'c', 'close'
  end
  content = keep || repo user token || '0a'x
  if IsWindows() then do
    call DelFile f
    call charout f, content
    call stream f, 'c', 'close'
  end
  else do
    call value 'RXPIP_CRED_CONTENT', content, 'ENVIRONMENT'
    '(umask 077; printf %s "$RXPIP_CRED_CONTENT" > "' || f || '.new" && mv "' || f || '.new" "' || f || '")'
    call value 'RXPIP_CRED_CONTENT', '', 'ENVIRONMENT'
  end
  return

CmdRegister: procedure expose home
  parse arg args
  user = OptValue(args, 'user')
  inv = OptValue(args, 'invite')
  if inv = '' then inv = value('RXPIP_INVITE',,'ENVIRONMENT')
  if user = '' | inv = '' then do
    say 'usage: rxpip register --user=<name> --invite=<code>   (invite from the repository admin)'
    exit 1
    return
  end
  repo = GetConfigValue(home, 'REPO_URL')
  out = ServerPost(repo, 'REGISTER', '', 'X-Rxpip-User: ' || user, 'X-Rxpip-Invite: ' || inv, '')
  if word(out,1) \= 'STATUS:' | word(out,2) \= 'OK' then do
    call ShowResponse out
    exit 1
    return
  end
  tok = StanzaFieldPlain(out, 'TOKEN')
  call SaveCredential home, repo, user, tok
  say 'registered as' user || '; your token was saved in' home || '/credentials.txt'
  say 'Treat that file like a password. You can now: rxpip publish ...'
  exit 0
  return

CmdLogin: procedure expose home
  parse arg args
  repo = GetConfigValue(home, 'REPO_URL')
  t = OptValue(args, 'token')
  if t = '' then t = value('RXPIP_TOKEN',,'ENVIRONMENT')
  if t = '' | \TokenLooksValid(t) then do
    say 'usage: rxpip login --token=<token>   (or set env RXPIP_TOKEN)'
    exit 1
    return
  end
  out = ServerPost(repo, 'WHOAMI', '', '', 'X-Rxpip-Token: ' || t, '')
  if word(out,1) \= 'STATUS:' | word(out,2) \= 'OK' then do
    call ShowResponse out
    exit 1
    return
  end
  u = StanzaFieldPlain(out, 'USER')
  call SaveCredential home, repo, u, t
  say 'logged in as' u
  exit 0
  return

CmdLogout: procedure expose home
  repo = GetConfigValue(home, 'REPO_URL')
  f = home || '/credentials.txt'
  keep = ''
  if FileExists(f) then do
    do while lines(f) > 0
      l = linein(f)
      parse var l r .
      if r \= repo & strip(l) \= '' then keep = keep || l || '0a'x
    end
    call stream f, 'c', 'close'
    call DelFile f
    if keep \= '' then do
      call charout f, keep
      call stream f, 'c', 'close'
    end
  end
  say 'logged out of' repo
  exit 0
  return

CmdWhoami: procedure expose home
  repo = GetConfigValue(home, 'REPO_URL')
  t = ResolveToken(home, repo, '')
  if t = '' then do
    say 'not logged in'
    exit 1
    return
  end
  out = ServerPost(repo, 'WHOAMI', '', '', 'X-Rxpip-Token: ' || t, '')
  rc = ShowResponse(out)
  exit rc
  return

CmdToken: procedure expose home
  parse arg sub '01'x rest
  sub = translate(sub)
  repo = GetConfigValue(home, 'REPO_URL')
  t = ResolveToken(home, repo, '')
  if t = '' then do
    say 'not logged in (rxpip login --token=T)'
    exit 1
    return
  end
  hdrs = ''
  select
    when sub = 'NEW' then do
      lbl = OptValue(rest, 'label')
      if lbl \= '' then hdrs = 'X-Rxpip-Label: ' || lbl
      out = ServerPost(repo, 'NEWTOKEN', '', hdrs, 'X-Rxpip-Token: ' || t, '')
    end
    when sub = 'LIST' then out = ServerPost(repo, 'TOKENS', '', '', 'X-Rxpip-Token: ' || t, '')
    when sub = 'REVOKE' then do
      parse var rest id '01'x .
      if id = '' then do
        say 'usage: rxpip token revoke <token-id>   (see: rxpip token list)'
        exit 1
        return
      end
      out = ServerPost(repo, 'REVOKE', '', 'X-Rxpip-Token-Id: ' || id, 'X-Rxpip-Token: ' || t, '')
    end
    otherwise do
      say 'usage: rxpip token new [--label=L] | list | revoke <id>'
      exit 1
      return
    end
  end
  rc = ShowResponse(out)
  exit rc
  return

CmdOwner: procedure expose home
  parse arg sub '01'x pkg '01'x who '01'x .
  sub = translate(sub)
  repo = GetConfigValue(home, 'REPO_URL')
  if pkg = '' | (sub \= 'LIST' & who = '') then do
    say 'usage: rxpip owner list <pkg> | add <pkg> <user> | remove <pkg> <user>'
    exit 1
    return
  end
  if sub = 'LIST' then do
    rc = ShowResponse(ServerGet(repo, 'OWNERS', 'name=' || UrlEncode(pkg)))
    exit rc
    return
  end
  if sub \= 'ADD' & sub \= 'REMOVE' then do
    say 'usage: rxpip owner list <pkg> | add <pkg> <user> | remove <pkg> <user>'
    exit 1
    return
  end
  t = ResolveToken(home, repo, '')
  if t = '' then do
    say 'not logged in (rxpip login --token=T)'
    exit 1
    return
  end
  out = ServerPost(repo, sub || 'OWNER', '', 'X-Rxpip-Name: ' || pkg || '01'x || 'X-Rxpip-User: ' || who, 'X-Rxpip-Token: ' || t, '')
  rc = ShowResponse(out)
  exit rc
  return

CmdConfig: procedure expose home
  parse arg sub '01'x rest
  sub = translate(sub)
  select
    when sub = 'GET' then do
      parse var rest key '01'x .
      key = strip(key)
      say key':' GetConfigValue(home, key)
    end
    when sub = 'SET' then do
      parse var rest key '01'x val '01'x .
      key = strip(key)
      val = strip(val)
      call SetConfigValue home, key, val
      say 'rxpip: set' key '=' val
    end
    otherwise do
      say 'REPO_URL:' GetConfigValue(home, 'REPO_URL')
      say 'LIB_DIR:' GetConfigValue(home, 'LIB_DIR')
      say 'INTERPRETER:' GetConfigValue(home, 'INTERPRETER')
    end
  end
  return

/* =======================================================================
   CONFIG
   ======================================================================= */

LoadOrInitConfig: procedure expose cfg. home
  parse arg home
  cf = home || '/config.txt'
  if \FileExists(cf) then do
    call charout cf, 'REPO_URL: https://www.rexxpository.org/cgi-bin/rxpip_server.rexx' || '0a'x
    call charout cf, 'LIB_DIR: ' || home || '/lib' || '0a'x
    call charout cf, 'INTERPRETER: regina' || '0a'x
    call stream cf, 'c', 'close'
  end
  cfg.REPO_URL = GetConfigValue(home, 'REPO_URL')
  cfg.LIB_DIR = GetConfigValue(home, 'LIB_DIR')
  cfg.INTERPRETER = GetConfigValue(home, 'INTERPRETER')
  return

GetConfigValue: procedure
  parse arg home, key
  cf = home || '/config.txt'
  key = translate(strip(key))
  if \FileExists(cf) then return ''
  val = ''
  do while lines(cf) > 0
    l = linein(cf)
    parse var l k ':' v
    if translate(strip(k)) = key then val = strip(v)
  end
  call stream cf, 'c', 'close'
  return val

SetConfigValue: procedure
  parse arg home, key, val
  cf = home || '/config.txt'
  tmp = cf || '.new'
  keyU = translate(strip(key))
  found = 0
  if FileExists(cf) then do
    do while lines(cf) > 0
      l = linein(cf)
      parse var l k ':' v
      if translate(strip(k)) = keyU then do
        call charout tmp, key || ': ' || val || '0a'x
        found = 1
      end
      else call charout tmp, l || '0a'x
    end
    call stream cf, 'c', 'close'
  end
  if \found then call charout tmp, key || ': ' || val || '0a'x
  call stream tmp, 'c', 'close'
  call MoveFile tmp, cf
  return

/* =======================================================================
   INSTALLED-PACKAGE REGISTRY  (home/installed.txt, stanza format)
   ======================================================================= */

InstalledVersion: procedure
  parse arg home, name
  rec = FindInstalledRecord(home, name)
  if rec = '' then return ''
  return StanzaFieldPlain(rec, 'VERSION')

FindInstalledRecord: procedure
  parse arg home, name
  idx = home || '/installed.txt'
  if \FileExists(idx) then return ''
  found = ''
  cur = ''
  inrec = 0
  do while lines(idx) > 0
    l = linein(idx)
    if left(l,5) = 'NAME:' then do
      if inrec & pos('NAME:' name, ' ' || cur) > 0 then leave
      cur = l || '0a'x
      inrec = 1
      curname = strip(substr(l,6))
    end
    else if l = '' then do
      if inrec & curname = name then do
        found = cur
        leave
      end
      cur = ''
      inrec = 0
    end
    else cur = cur || l || '0a'x
  end
  if found = '' & inrec & curname = name then found = cur
  call stream idx, 'c', 'close'
  return found

RemoveInstalledRecord: procedure
  parse arg home, name
  idx = home || '/installed.txt'
  if \FileExists(idx) then return
  tmp = idx || '.new'
  skip = 0
  do while lines(idx) > 0
    l = linein(idx)
    if left(l,5) = 'NAME:' then do
      curname = strip(substr(l,6))
      skip = (curname = name)
    end
    if \skip then call charout tmp, l || '0a'x
    if l = '' then skip = 0
  end
  call stream idx, 'c', 'close'
  call stream tmp, 'c', 'close'
  call MoveFile tmp, idx
  return

RecordInstalled: procedure expose home
  parse arg home, name, ver, author, summary, requires, files
  call RemoveInstalledRecord home, name
  idx = home || '/installed.txt'
  call charout idx, 'NAME: ' || name || '0a'x
  call charout idx, 'VERSION: ' || ver || '0a'x
  call charout idx, 'AUTHOR: ' || author || '0a'x
  call charout idx, 'SUMMARY: ' || summary || '0a'x
  call charout idx, 'REQUIRES: ' || requires || '0a'x
  call charout idx, 'FILES: ' || files || '0a'x
  call charout idx, '0a'x
  call stream idx, 'c', 'close'
  return

/* =======================================================================
   HTTP TRANSPORT  (shells out to curl; text responses read back in full)
   ======================================================================= */

/* GET <repo_url>?action=X&<extra>  ->  full response body (text) */
ServerGet: procedure
  parse arg repo, action, extra
  url = repo || '?action=' || action
  if extra \= '' then url = url || '&' || extra
  tmp = TempDir() || '/rxpip_resp_' || time('L') || '_' || random(1,99999) || '.tmp'
  'curl -s -o "' || tmp || '" "' || url || '"'
  out = ''
  if FileExists(tmp) then do
    do while lines(tmp) > 0
      out = out || linein(tmp) || '0a'x
    end
    call stream tmp, 'c', 'close'
  end
  call DelFile tmp
  return out

/* download one specific artifact (kind/platform) to outfile; 0 on success */
ServerDownload: procedure
  parse arg repo, name, ver, kind, platform, outfile
  url = repo || '?action=DOWNLOAD&name=' || UrlEncode(name)
  if ver \= '' then url = url || '&version=' || UrlEncode(ver)
  url = url || '&kind=' || UrlEncode(kind) || '&platform=' || UrlEncode(platform)
  'curl -s -f -o "' || outfile || '" "' || url || '"'
  if \FileExists(outfile) then return 1
  sz = stream(outfile, 'c', 'query size')
  if sz = 0 then return 1
  return 0

/* POST to the server. hdrs = '01'x-separated "Name: value" lines that are
   not secret; secrets = '01'x-separated header lines that ARE secret (the
   token, an invite code). Secrets never go in the URL (URLs are logged)
   nor on curl's command line (visible in `ps`): they travel through a
   private temporary header file (curl -H @file). bodyfile may be ''.
   Returns the response text ('' if the server could not be reached). */
ServerPost: procedure
  parse arg repo, action, extra, hdrs, secrets, bodyfile
  url = repo || '?action=' || action
  if extra \= '' then url = url || '&' || extra
  uniq = time('L') || '_' || random(1,99999)
  hdrfile = TempDir() || '/rxpip_hdr_' || uniq || '.tmp'
  tmp = TempDir() || '/rxpip_post_' || uniq || '.tmp'
  if IsWindows() then do
    call charout hdrfile, translate(secrets, '0a'x, '01'x) || '0d0a'x
    call stream hdrfile, 'c', 'close'
  end
  else do
    call value 'RXPIP_SECRET_HDRS', translate(secrets, '0a'x, '01'x), 'ENVIRONMENT'
    '(umask 077; printf "%s\n" "$RXPIP_SECRET_HDRS" > "' || hdrfile || '")'
    call value 'RXPIP_SECRET_HDRS', '', 'ENVIRONMENT'
  end
  cmd = 'curl -s -o "' || tmp || '" -X POST -H @"' || hdrfile || '"'
  do while hdrs \= ''
    parse var hdrs h '01'x hdrs
    if h \= '' then cmd = cmd || ' -H "' || h || '"'
  end
  if bodyfile \= '' then cmd = cmd || ' --data-binary @"' || bodyfile || '"'
  else cmd = cmd || ' -d ""'
  cmd = cmd || ' "' || url || '"'
  cmd
  call DelFile hdrfile
  out = ''
  if FileExists(tmp) then do
    do while lines(tmp) > 0
      out = out || linein(tmp) || '0a'x
    end
    call stream tmp, 'c', 'close'
  end
  call DelFile tmp
  return out

/* publish a package: raw artifact bytes as the POST body, metadata as
   X-Rxpip-* headers (non-secret) and the token as a secret header */
ServerPublish: procedure
  parse arg repo, pkgfile, name, ver, author, summary, requires, kind, platform, token
  hdrs = 'X-Rxpip-Name: ' || name || '01'x ||,
         'X-Rxpip-Version: ' || ver || '01'x ||,
         'X-Rxpip-Author: ' || author || '01'x ||,
         'X-Rxpip-Summary: ' || summary || '01'x ||,
         'X-Rxpip-Requires: ' || requires || '01'x ||,
         'X-Rxpip-Kind: ' || kind || '01'x ||,
         'X-Rxpip-Platform: ' || platform
  out = ServerPost(repo, 'PUBLISH', '', hdrs, 'X-Rxpip-Token: ' || token, pkgfile)
  return ShowResponse(out)

/* print a server response; 0 if it says STATUS: OK, else 1 */
ShowResponse: procedure
  parse arg out
  say out
  if out = '' then do
    say 'rxpip: no response from server'
    return 1
  end
  if word(out,1) = 'STATUS:' & word(out,2) = 'OK' then return 0
  return 1

/* =======================================================================
   TEXT / STANZA UTILITIES
   ======================================================================= */

/* This machine's artifact-selection tag: <interpreter>-<os>-<arch>,
   e.g. "regina-linux-x86_64". Used to prefer an exact BYTECODE
   artifact when one has been published; SOURCE/any always matches
   as the universal fallback (see server's artifact-model note). */
PlatformTag: procedure expose cfg.
  interp = cfg.INTERPRETER
  if interp = '' then interp = 'regina'
  if IsWindows() then do
    /* no shell-out needed -- Windows sets these env vars itself */
    os = 'windows'
    arch = translate(value('PROCESSOR_ARCHITECTURE',,'ENVIRONMENT'))
    if arch = 'AMD64' then arch = 'x86_64'
    else if arch = 'ARM64' then arch = 'arm64'
    else if arch = '' then arch = 'x86_64'
  end
  else do
    tmp = TempDir() || '/rxpip_uname_' || time('L') || '_' || random(1,99999) || '.tmp'
    'uname -s > "' || tmp || '"'
    os = ''
    if FileExists(tmp) then do
      os = translate(strip(linein(tmp)))
      call stream tmp, 'c', 'close'
    end
    call DelFile tmp
    tmp = TempDir() || '/rxpip_arch_' || time('L') || '_' || random(1,99999) || '.tmp'
    'uname -m > "' || tmp || '"'
    arch = ''
    if FileExists(tmp) then do
      arch = strip(linein(tmp))
      call stream tmp, 'c', 'close'
    end
    call DelFile tmp
  end
  return translate(interp) || '-' || os || '-' || arch

/* pick the best artifact from an ARTIFACTS response: an exact
   PLATFORM match wins, else SOURCE/any, else '' (nothing usable).
   Returns "KIND '01'x PLATFORM '01'x FILES" or ''. */
SelectBestArtifact: procedure
  parse arg resp, platformtag
  bestSource = ''
  bestExact = ''
  curK = ''; curP = ''
  do while resp \= ''
    parse var resp line '0a'x resp
    if left(line,5) = 'KIND:' then curK = strip(substr(line,6))
    else if left(line,9) = 'PLATFORM:' then curP = strip(substr(line,10))
    else if left(line,6) = 'FILES:' then do
      curF = strip(substr(line,7))
      if translate(curK) = 'SOURCE' & translate(curP) = 'ANY' then ,
        bestSource = curK || '01'x || curP || '01'x || curF
      if translate(curP) = translate(platformtag) then ,
        bestExact = curK || '01'x || curP || '01'x || curF
      curK = ''; curP = ''
    end
  end
  if bestExact \= '' then return bestExact
  return bestSource

/* first line of a ServerGet() response is "STATUS: OK" or "STATUS: ERROR";
   return just the word after STATUS: for a quick check */
InfoMessage: procedure
  parse arg resp
  do while resp \= ''
    parse var resp line '0a'x resp
    if left(line,8) = 'MESSAGE:' then return strip(substr(line,9))
  end
  return '(no message)'

/* extract "word(resp,1)" style status token: returns OK or ERROR */
/* (kept simple: caller does word(resp,1) after this normalises resp to
   start with the STATUS line's second token) */

/* return field value (first occurrence) from a full multi-stanza response,
   e.g. StanzaField(resp,'VERSION') on a single-record INFO response */
StanzaField: procedure
  parse arg resp, key
  tag = key || ':'
  do while resp \= ''
    parse var resp line '0a'x resp
    if left(line, length(tag)) = tag then return strip(substr(line, length(tag)+1))
  end
  return ''

/* same, but operating on a plain "0a"x-joined single record string
   (used for installed.txt records, which use "KEY: value" too) */
StanzaFieldPlain: procedure
  parse arg rec, key
  return StanzaField(rec, key)

PrintStanzas: procedure
  parse arg resp
  do while resp \= ''
    parse var resp line '0a'x resp
    if line = 'STATUS: OK' then iterate
    if left(line,6) = 'COUNT:' then iterate
    if line = '' then do
      say ''
      iterate
    end
    say line
  end
  return

StripFirstLine: procedure
  parse arg s
  parse var s l '0a'x .
  return l

WithVer: procedure
  parse arg v
  if v = '' then return ''
  return '&version=' || UrlEncode(v)

/* -1,0,1 dotted-numeric version compare (same algorithm as server) */
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

UrlEncode: procedure
  parse arg s
  out = ''
  do i = 1 to length(s)
    c = substr(s,i,1)
    if verify(c,'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~') = 0 then out = out || c
    else if c = ' ' then out = out || '+'
    else out = out || '%' || c2x(c)
  end
  return out

/* args is '01'x-delimited (see main dispatch); this preserves values
   with embedded spaces, e.g. --summary="a description with spaces" */
OptValue: procedure
  parse arg args, key
  needle = '--' || key || '='
  do while args \= ''
    parse var args w '01'x args
    if left(w, length(needle)) = needle then return substr(w, length(needle)+1)
  end
  return ''

/* POSIX single-quote shell quoting: wrap in '...', turning any
   embedded ' into '\'' (close quote, escaped quote, reopen quote).
   Used to pass argv elements through a shell command line intact. */
/* Quote one argv element so it survives a shell command line intact.
   Unix: standard POSIX single-quoting. Windows/cmd.exe has no single-
   quote string syntax at all (a ' is just a literal character there),
   so this branches to double-quote wrapping with doubled embedded
   quotes -- adequate for ordinary text and paths, but cmd.exe's own
   parsing layer (on top of whatever the target program's argv parser
   does) has real edge cases around &, |, <, >, ^ and %; values that
   need to survive those are a known residual risk on Windows -- see
   the Windows notes in ARCHITECTURE.md. */
ShellQuote: procedure
  parse arg s
  if IsWindows() then do
    out = ''
    do while s \= ''
      p = pos('"', s)
      if p = 0 then do
        out = out || s
        s = ''
      end
      else do
        out = out || substr(s,1,p-1) || '""'
        s = substr(s,p+1)
      end
    end
    return '"' || out || '"'
  end
  out = "'"
  do while s \= ''
    p = pos("'", s)
    if p = 0 then do
      out = out || s
      s = ''
    end
    else do
      out = out || substr(s,1,p-1) || "'\''"
      s = substr(s,p+1)
    end
  end
  return out || "'"

Basename: procedure
  parse arg p
  do while pos('/', p) > 0
    parse var p . '/' p
  end
  return p

/* directory portion of a path; '.' if there is none */
Dirname: procedure
  parse arg p
  last = 0
  do i = 1 to length(p)
    if substr(p,i,1) = '/' then last = i
  end
  if last = 0 then return '.'
  if last = 1 then return '/'
  return substr(p, 1, last-1)

FileExists: procedure
  parse arg fn
  rc = stream(fn, 'c', 'query exists')
  return rc \= ''

/* -----------------------------------------------------------------
   OS PORTABILITY LAYER -- everything below is the one place platform
   differences live. All other client logic (protocol, parsing, the
   command handlers above) is unchanged between Windows and Unix; only
   how we shell out for filesystem/archive operations differs.
   ----------------------------------------------------------------- */

IsWindows: procedure
  if translate(value('OS',,'ENVIRONMENT')) = 'WINDOWS_NT' then return 1
  if value('COMSPEC',,'ENVIRONMENT') \= '' then return 1
  return 0

TempDir: procedure
  if IsWindows() then do
    t = value('TEMP',,'ENVIRONMENT')
    if t = '' then t = value('TMP',,'ENVIRONMENT')
    if t = '' then t = 'C:/Windows/Temp'
    return translate(t, '/', '\')
  end
  return '/tmp'

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

CopyFile: procedure
  parse arg src, dst
  if IsWindows() then 'copy /y "' || translate(src,'\','/') || '" "' || translate(dst,'\','/') || '" >nul' ,
                       '2>nul'
  else 'cp "' || src || '" "' || dst || '"' '2>/dev/null'
  return

EnsureDir: procedure
  parse arg d
  if IsWindows() then 'mkdir "' || translate(d,'\','/') || '" 2>nul'
  else 'mkdir -p "' || d || '"'
  return

/* run a command with dir as the working directory; returns its RC
   (isolated procedures don't share RC with their caller in REXX, so
   this must be captured and returned explicitly rather than left for
   the caller to read RC after the CALL) */
RunInDir: procedure
  parse arg dir, cmdline
  if IsWindows() then 'cd /d "' || translate(dir,'\','/') || '" && ' || cmdline
  else 'cd "' || dir || '" && ' || cmdline
  return rc

Bomb:
  say 'rxpip: internal error at line' sigl':' errortext(rc)
  exit 1
