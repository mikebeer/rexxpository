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
if IsOoRexx() & arg() = 1 & value('RXPIP_QUOTED',,'ENVIRONMENT') \= '' then do
  /* ooRexx hands the whole command line over as ONE string; the launcher
     (client/oorexx/rxpip-oorexx[.bat]) double-quotes every argument so we
     can split it again here. RXPIP_QUOTED=1: backslash escapes inside the
     quotes (sh launcher); =2: no escapes (Windows launcher). */
  allargs = SplitQuoted(arg(1), value('RXPIP_QUOTED',,'ENVIRONMENT'))
end
else do i = 1 to arg()
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
cfg.READTOKEN = ResolveToken(home, cfg.REPO_URL, '')   /* sent with every read, for private packages */
call SetClientHeader

parse var allargs cmd '01'x rest
cmd = translate(cmd)

/* install scope: commands that manage installed packages work on the
   CURRENT DIRECTORY by default (files in ., record in ./.rxpip);
   --global uses the shared store, --target DIR another directory.
   run/build merge the shared store, so they always use it. */
if wordpos(cmd, 'INSTALL UNINSTALL LIST FREEZE SCAN') > 0 then rest = ParseScope(rest)
else call SetScope 'GLOBAL'

if wordpos(cmd, 'INSTALL SEARCH SHOW RUN') > 0 then call CheckClientUpdate home

select
  when cmd = 'UPDATE'    then call CmdUpdate rest
  when cmd = 'ADMIN'     then call CmdAdmin rest
  when cmd = 'INSTALL'   then call CmdInstall rest
  when cmd = 'UNINSTALL' then call CmdUninstall rest
  when cmd = 'LIST'      then call CmdList
  when cmd = 'SEARCH'    then call CmdSearch rest
  when cmd = 'SHOW'      then call CmdShow rest
  when cmd = 'FREEZE'    then call CmdFreeze
  when cmd = 'PATH'      then call CmdPath
  when cmd = 'FIND'      then call CmdFind rest
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
  when cmd = 'VISIBILITY' then call CmdVisibility rest
  when cmd = 'READER'    then call CmdReader rest
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
  say '  install [--upgrade] <name>[==version]   install a package (and its deps) into the current'
  say '                              directory; --upgrade/-U updates an installed one'
  say '  uninstall <name>            remove an installed package'
  say '  list                        list installed packages'
  say '  find [dir...] [--sync]      find installs under dirs (default .), show duplicates/older copies;'
  say '                              --sync brings older copies up to the newest version found'
  say ''
  say 'Scope options (install, uninstall, list, freeze, scan):'
  say '  --global, -g               use the shared store (~/.rxpip/lib) instead of the current directory'
  say '  --target=DIR, -t DIR       use directory DIR'
  say '  --force                    overwrite files that rxpip did not install'
  say ''
  say '  search <term>               search the repository'
  say '  show <name>                 show repository details for a package'
  say '  freeze                      print installed packages as name==version'
  say '  scan <file.rexx>            install packages named in /* REQUIRE */'
  say '  run <file.rexx> [args]      scan + auto-install, merge, then execute'
  say '  build <file.rexx> [--output=out]  scan + auto-install, write merged standalone .rexx'
  say '  publish <pkgfile> --name=N --version=V [...] [--private]   upload a package (needs login)'
  say '  register --user=U --invite=CODE   create an account (invite-only); saves your token'
  say '  login [--token=T]           save a token (or read it from env RXPIP_TOKEN)'
  say '  logout | whoami             forget / show the saved login'
  say '  token new [--label=L] | list | revoke <id>   manage your API tokens'
  say '  owner list|add|remove <pkg> [user]   manage who may publish a package'
  say '  visibility <pkg> [public|private]   show / set whether a package is public (owners)'
  say '  reader list|add|remove <pkg> [user]   who may read a private package besides its owners'
  say '  update [--check]            check for a newer rxpip and install it (this client: ' || ClientVersion() || ')'
  say '  admin stats [--days=N] | users | lock <user> | client-publish <kind> --version=V <files>'
  say '                              administrator commands (need an administrator token)'
  say '  config get|set <key> [val]  view/change REPO_URL, LIB_DIR, INTERPRETER, AUTOUPDATE, CLIENT_CHECK'
  say '  path                        show the library directory and how to put it on PATH'
  say '  help                        this message'
  return

CmdInstall: procedure expose home cfg.
  parse arg all
  spec = ''
  upg = 0
  do while all \= ''
    parse var all one '01'x all
    if one = '--upgrade' | one = '-U' then upg = 1
    else if spec = '' then spec = strip(one)
  end
  if spec = '' then do
    say 'usage: rxpip install [--upgrade] <name>[==version]'
    exit 1
    return
  end
  cfg.UPGRADE = upg
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

  /* --upgrade applies to the package named on the command line only */
  upg = cfg.UPGRADE
  cfg.UPGRADE = 0

  curver = InstalledVersion(cfg.RECDIR, name)
  newer = 0
  if curver \= '' & upg & wantver = '' & minver = '' then do
    info0 = ServerGet(cfg.REPO_URL, 'INFO', 'name=' || UrlEncode(name))
    if StanzaField(info0, 'STATUS') = 'OK' then do
      if CompareVersions(StanzaField(info0, 'VERSION'), curver) > 0 then newer = 1
    end
  end
  if curver \= '' & \newer then do
    if (wantver = '' & minver = '') | (wantver \= '' & CompareVersions(curver, wantver) >= 0) | ,
       (minver \= '' & CompareVersions(curver, minver) >= 0) then do
      say 'rxpip: ' || name || ' ' || curver || ' already installed'
      /* still walk its dependencies -- they may have been individually
         uninstalled since, and "already installed" must not mean
         "assume its whole dependency tree is still intact" */
      rec = FindInstalledRecord(cfg.RECDIR, name)
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

  if curver \= '' then do
    /* replacing an older version: drop its files from lib/ first, so a
       file that no longer exists in the new version does not linger */
    oldfiles = StanzaFieldPlain(FindInstalledRecord(cfg.RECDIR, name), 'FILES')
  end
  else oldfiles = ''

  /* never silently overwrite a file that rxpip did not put there */
  if \cfg.FORCEOW then do
    do i = 1 to words(files)
      fn = word(files, i)
      if StoreExists(cfg.TGTDIR, fn) & wordpos(fn, oldfiles) = 0 then do
        say "rxpip: '" || cfg.TGTDIR || '/' || fn || "' already exists and was not installed by rxpip; use --force to overwrite"
        return seen
      end
    end
  end
  do i = 1 to words(oldfiles)
    call StoreDelete cfg.TGTDIR, word(oldfiles, i)
  end

  pkgdir = home || '/pkgs/' || name || '/' || ver
  call EnsureDir pkgdir
  call Unblock cachefile
  'tar xzf "' || cachefile || '" -C "' || pkgdir || '" 2>' || NullSink()
  call Unblock pkgdir

  /* flatten: copy every package file (any extension: .rexx, .rex, ...) into the shared lib/ dir so that
     unqualified CALLs resolve for `rxpip run` */
  call StoreMake cfg.TGTDIR
  do i = 1 to words(files)
    fn = word(files, i)
    call StoreCopyIn pkgdir, cfg.TGTDIR, fn
  end

  call RecordInstalled cfg.RECDIR, name, ver, author, summary, requires, files

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

/* ---- install scope ------------------------------------------------- */

/* cfg.TGTDIR = directory that receives the package files
   cfg.RECDIR = directory holding installed.txt for that scope
   cfg.ISGLOBAL = 1 for the shared store */
SetScope: procedure expose cfg. home
  parse arg mode, dir
  if IsCms() then do
    /* VM/370plus: the "directory" is a minidisk filemode; the shared
       store is the one named by LIB_DIR in the config (default A) */
    if mode = 'GLOBAL' then do
      cfg.ISGLOBAL = 1
      dir = left(cfg.LIB_DIR, 1)
    end
    else do
      cfg.ISGLOBAL = 0
      if dir = '' then dir = 'A'
    end
    if dir = '' | dir = '/' then dir = 'A'
    cfg.TGTDIR = translate(left(dir,1))
    cfg.RECDIR = 'CMS:' || cfg.TGTDIR
    return
  end
  if mode = 'GLOBAL' then do
    cfg.ISGLOBAL = 1
    cfg.TGTDIR = home || '/lib'
    cfg.RECDIR = home
  end
  else do
    if dir = '' then dir = directory()
    dir = translate(dir, '/', '\')
    if length(dir) > 1 & right(dir,1) = '/' then dir = left(dir, length(dir)-1)
    cfg.ISGLOBAL = 0
    cfg.TGTDIR = dir
    cfg.RECDIR = dir || '/.rxpip'
  end
  return

/* strip --global/-g/--target=DIR/-t DIR/--force from the argument list
   ('01'x separated) and set the scope; returns the remaining arguments */
ParseScope: procedure expose cfg. home
  parse arg all
  mode = 'LOCAL'
  dir = ''
  kept = ''
  do while all \= ''
    parse var all one '01'x all
    if one = '--global' | one = '-g' then mode = 'GLOBAL'
    else if left(one, 9) = '--target=' then dir = substr(one, 10)
    else if one = '-t' | one = '--target' then parse var all dir '01'x all
    else if one = '--force' then cfg.FORCEOW = 1
    else kept = kept || one || '01'x
  end
  if dir \= '' then mode = 'LOCAL'
  call SetScope mode, dir
  return kept

/* ---- rxpip find ------------------------------------------------------ */

/* list all package records under the given directories (and the shared
   store), report packages present in several places or in different
   versions; --sync upgrades older copies to the newest version found */
CmdFind: procedure expose home cfg.
  parse arg all
  if IsCms() then do
    say 'rxpip: find is not available on CMS yet'
    return
  end
  sync = 0
  dupnames = ''
  roots = ''
  do while all \= ''
    parse var all one '01'x all
    if one = '' then iterate
    if one = '--sync' then sync = 1
    else roots = roots || one || '01'x
  end
  if roots = '' then roots = directory() || '01'x

  /* locations: lines "recdir" */
  locs = home || '0a'x
  do while roots \= ''
    parse var roots r '01'x roots
    r = translate(r, '/', '\')
    tmp = TempDir() || '/rxpip_find_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
    if IsWindows() then ,
      'dir /s /b "' || translate(r,'\','/') || '\installed.txt" > "' || translate(tmp,'\','/') || '" 2>nul'
    else ,
      'find "' || r || '" -name installed.txt -path "*/.rxpip/installed.txt" > "' || tmp || '" 2>/dev/null'
    if FileExists(tmp) then do
      do while lines(tmp) > 0
        f = translate(linein(tmp), '/', '\')
        if pos('/.rxpip/installed.txt', f) = 0 then iterate
        d = left(f, length(f) - length('/installed.txt'))
        if wordpos(d, translate(locs, ' ', '0a'x)) = 0 then locs = locs || d || '0a'x
      end
      call stream tmp, 'c', 'close'
    end
    call DelFile tmp
  end

  /* collect "name version recdir" entries */
  n = 0
  best. = ''
  rest = locs
  do while rest \= ''
    parse var rest d '0a'x rest
    if d = '' then iterate
    sm = RecSummary(d)
    do while sm \= ''
      parse var sm nm '01'x ver '01'x su '0a'x sm
      n = n + 1
      ename.n = nm
      ever.n = ver
      edir.n = d
      if best.nm = '' then best.nm = ver
      else if CompareVersions(ver, best.nm) > 0 then best.nm = ver
    end
  end
  if n = 0 then do
    say '(no rxpip installs found)'
    return
  end

  say left('NAME',20) left('VERSION',12) 'LOCATION'
  say copies('-', 70)
  todo = 0
  do i = 1 to n
    nm = ename.i
    loc = edir.i
    if loc = home then show = '(shared store) ' || home
    else show = left(loc, length(loc) - length('/.rxpip'))
    note = ''
    if CompareVersions(ever.i, best.nm) < 0 then do
      note = '  <- older than' best.nm
      todo = todo + 1
      fixname.todo = nm
      fixdir.todo = loc
      fixver.todo = best.nm
    end
    say left(nm,20) left(ever.i,12) show || note
  end

  /* duplicates summary */
  dup = 0
  do i = 1 to n
    c = 0
    do j = 1 to n
      if ename.j = ename.i then c = c + 1
    end
    if c > 1 & wordpos(ename.i, dupnames) = 0 then do
      dupnames = dupnames ename.i
      dup = dup + 1
    end
  end
  say ''
  say n 'install(s),' dup 'package(s) in more than one place,' todo 'outdated.'

  if sync & todo > 0 then do
    say ''
    do k = 1 to todo
      if fixdir.k = home then call SetScope 'GLOBAL'
      else call SetScope 'LOCAL', left(fixdir.k, length(fixdir.k) - length('/.rxpip'))
      cfg.UPGRADE = 1
      say 'rxpip: updating' fixname.k 'in' cfg.TGTDIR
      call InstallOne fixname.k || '==' || fixver.k, ''
    end
  end
  else if todo > 0 then say "Run 'rxpip find --sync' to bring the older copies up to date."
  return

CmdPath: procedure expose home cfg.
  lib = cfg.LIB_DIR
  say lib
  say ''
  say 'Installed package files are plain files in this directory. Put it on PATH once'
  say 'and Regina (or ooRexx) finds them from any script, without rxpip run:'
  say ''
  if IsOS2() then do
    wl = translate(lib, '\', '/')
    say '  SET PATH=%PATH%;' || wl || '      (add to the PATH line in CONFIG.SYS)'
  end
  else if IsWindows() then do
    wl = translate(lib, '\', '/')
    say '  setx PATH "%PATH%;' || wl || '"'
  end
  else do
    say '  export PATH="$PATH:' || lib || '"      (add to ~/.profile)'
  end
  return

CmdUninstall: procedure expose home cfg.
  parse arg name '01'x .
  name = strip(name)
  if name = '' then do
    say 'usage: rxpip uninstall <name>'
    exit 1
    return
  end
  rec = FindInstalledRecord(cfg.RECDIR, name)
  if rec = '' then do
    say "rxpip: '" || name || "' is not installed"
    exit 1
    return
  end
  files = StanzaFieldPlain(rec, 'FILES')
  do i = 1 to words(files)
    fn = word(files, i)
    call StoreDelete cfg.TGTDIR, fn
  end
  if cfg.ISGLOBAL then call DelTree home || '/pkgs/' || name
  call RemoveInstalledRecord cfg.RECDIR, name
  say 'rxpip: removed' name
  return

CmdList: procedure expose home cfg.
  sm = RecSummary(cfg.RECDIR)
  if sm = '' then do
    say '(no packages installed)'
    return
  end
  say left('NAME',20) left('VERSION',12) 'SUMMARY'
  say copies('-', 60)
  do while sm \= ''
    parse var sm nm '01'x ver '01'x su '0a'x sm
    say left(nm,20) left(ver,12) su
  end
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

CmdFreeze: procedure expose home cfg.
  sm = RecSummary(cfg.RECDIR)
  do while sm \= ''
    parse var sm nm '01'x ver '01'x su '0a'x sm
    say nm || '==' || ver
  end
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
  rawargs = ''
  do while argrest \= ''
    parse var argrest one '01'x argrest
    if one = '' then iterate
    passthru = passthru || ' ' || ShellQuote(one)
    rawargs = rawargs || one || '01'x
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

  merged = home || '/run_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.rexx'
  call MergeScript fn, home, merged

  interp = Interpreter()

  if IsOoRexx() then do
    /* no 'rexx -a' in ooRexx: a small runner calls the merged program as an
       external routine with real separate arguments */
    runner = home || '/runner_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.rexx'
    call charout runner, "f = value('RXPIP_RUN_FILE',,'ENVIRONMENT')" || '0a'x
    call charout runner, "s = value('RXPIP_RUN_ARGS',,'ENVIRONMENT')" || '0a'x
    call charout runner, "a = .array~new" || '0a'x
    call charout runner, "do while s \= ''" || '0a'x
    call charout runner, "  parse var s one '01'x s" || '0a'x
    call charout runner, "  a~append(one)" || '0a'x
    call charout runner, "end" || '0a'x
    call charout runner, "res = .routine~newFile(f)~callWith(a)" || '0a'x
    call charout runner, "if datatype(res, 'W') then exit res" || '0a'x
    call charout runner, "exit 0" || '0a'x
    call stream runner, 'c', 'close'
    call value 'RXPIP_RUN_FILE', merged, 'ENVIRONMENT'
    call value 'RXPIP_RUN_ARGS', translate(rawargs, '01'x, '01'x), 'ENVIRONMENT'
    runrc = RunInDir(Dirname(merged), interp || ' "' || runner || '"')
    call value 'RXPIP_RUN_FILE', '', 'ENVIRONMENT'
    call value 'RXPIP_RUN_ARGS', '', 'ENVIRONMENT'
    call DelFile runner
  end
  else runrc = RunInDir(Dirname(merged), interp || ' -a "./' || Basename(merged) || '"' || passthru)
  call DelFile merged
  exit runrc

CmdBuild: procedure expose home cfg.
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
  if IsOS2() then do      /* no parenthesised command groups: copy in REXX */
    call LoadUtil
    call DelFile outfile
    do while lines(srcfile) > 0
      call lineout outfile, linein(srcfile)
    end
    call stream srcfile, 'c', 'close'
    call lineout outfile, ''
    call lineout outfile, 'exit'
    call SysFileTree translate(home,'\','/') || '\lib\*', 'lf.', 'FO'
    do i = 1 to lf.0
      do while lines(lf.i) > 0
        call lineout outfile, linein(lf.i)
      end
      call stream lf.i, 'c', 'close'
    end
    call stream outfile, 'c', 'close'
  end
  else if IsWindows() then do
    wsrc = translate(srcfile,'\','/')
    wlib = translate(home,'\','/') || '\lib\*'
    wout = translate(outfile,'\','/')
    '(type "' || wsrc || '" & echo. & echo exit & type "' || wlib || '" 2>nul) > "' || wout || '"'
  end
  else do
    '(cat "' || srcfile || '"; echo; echo "exit"; cat "' || home || '/lib/"* 2>/dev/null) > "' || outfile || '"'
  end
  return

CmdPublish: procedure expose home cfg.
  parse arg args
  parse var args pkgfile '01'x .
  if pkgfile = '' | \FileExists(pkgfile) then do
    say 'usage: rxpip publish <file.rxpkg> --name=X --version=Y [--token=T]' ,
        '[--author=A --summary=S --requires=R --kind=SOURCE|BYTECODE --platform=TAG --private|--public]'
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
  vis = ''
  if HasFlag(args, '--private') then vis = 'private'
  if HasFlag(args, '--public') then vis = 'public'
  rc = ServerPublish(cfg.REPO_URL, pkgfile, name, ver, author, summary, requires, kind, platform, token, vis)
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
  if StanzaField(out, 'STATUS') \= 'OK' then do
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
  if StanzaField(out, 'STATUS') \= 'OK' then do
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

CmdOwner: procedure expose home cfg.
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

/* rxpip visibility <pkg> [public|private]  -- owners; without a value, show it */
CmdVisibility: procedure expose home cfg.
  parse arg pkg '01'x val '01'x .
  repo = GetConfigValue(home, 'REPO_URL')
  val = translate(val, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
  if pkg = '' | (val \= '' & val \= 'public' & val \= 'private') then do
    say 'usage: rxpip visibility <pkg> [public|private]'
    exit 1
    return
  end
  t = ResolveToken(home, repo, '')
  if t = '' then do
    say 'not logged in (rxpip login --token=T)'
    exit 1
    return
  end
  if val = '' then out = ServerPost(repo, 'READERS', '', 'X-Rxpip-Name: ' || pkg, 'X-Rxpip-Token: ' || t, '')
  else out = ServerPost(repo, 'VISIBILITY', '', 'X-Rxpip-Name: ' || pkg || '01'x || 'X-Rxpip-Value: ' || val, 'X-Rxpip-Token: ' || t, '')
  rc = ShowResponse(out)
  exit rc
  return

/* rxpip reader list <pkg> | add <pkg> <user> | remove <pkg> <user>
   -- who may read a private package besides its owners */
CmdReader: procedure expose home cfg.
  parse arg sub '01'x pkg '01'x who '01'x .
  sub = translate(sub)
  repo = GetConfigValue(home, 'REPO_URL')
  if pkg = '' | (sub \= 'LIST' & who = '') | wordpos(sub, 'LIST ADD REMOVE') = 0 then do
    say 'usage: rxpip reader list <pkg> | add <pkg> <user> | remove <pkg> <user>'
    exit 1
    return
  end
  t = ResolveToken(home, repo, '')
  if t = '' then do
    say 'not logged in (rxpip login --token=T)'
    exit 1
    return
  end
  act = 'READERS'
  if sub = 'ADD' then act = 'ADDREADER'
  if sub = 'REMOVE' then act = 'REMOVEREADER'
  out = ServerPost(repo, act, '', 'X-Rxpip-Name: ' || pkg || '01'x || 'X-Rxpip-User: ' || who, 'X-Rxpip-Token: ' || t, '')
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
  cfg.UPGRADE = 0
  cfg.FORCEOW = 0
  cfg.READTOKEN = ''
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
   STORAGE BACKENDS and INSTALLED-PACKAGE REGISTRY

   Everything that knows WHERE packages live is in this section, so a
   different environment only has to supply these few routines:

     RecLoad(rec)            whole record text of a scope ('' if none)
     RecSave(rec, text)      replace it ('' removes it)
     StoreExists(tgt, fn)    does package file fn exist in the target?
     StoreCopyIn(src, tgt, fn)   copy a file from the unpacked package in
     StoreDelete(tgt, fn)    remove it
     StoreMake(tgt)          create the target if needed

   'rec' and 'tgt' are opaque strings made by SetScope. Two backends:
     DIR  directories (Unix, Windows): rec = <dir>/.rxpip, tgt = <dir>
     CMS  VM/370plus (no directories, 8.8 file names): rec = 'CMS:<mode>',
          tgt = a filemode letter; records live in GLOBALV group RXPIP.
   The CMS routines are a SKELETON: they show the intended mapping and
   are untested; see ARCHITECTURE.md ("VM/370plus").
   ======================================================================= */

IsCms: procedure
  parse source os .
  return (translate(left(os,3)) = 'CMS')

/* ---- record text ------------------------------------------------------ */
RecLoad: procedure
  parse arg rec
  if left(rec,4) = 'CMS:' then return CmsRecLoad(substr(rec,5))
  idx = rec || '/installed.txt'
  if \FileExists(idx) then return ''
  txt = ''
  do while lines(idx) > 0
    txt = txt || linein(idx) || '0a'x
  end
  call stream idx, 'c', 'close'
  return txt

RecSave: procedure
  parse arg rec, txt
  if left(rec,4) = 'CMS:' then do
    call CmsRecSave substr(rec,5), txt
    return
  end
  idx = rec || '/installed.txt'
  call DelFile idx
  if txt = '' then return
  call EnsureDir rec
  tmp = idx || '.new'
  call DelFile tmp
  call charout tmp, txt
  call stream tmp, 'c', 'close'
  call MoveFile tmp, idx
  return

/* ---- package files ----------------------------------------------------- */
StoreMake: procedure
  parse arg tgt
  if IsCms() then return            /* a minidisk is already there */
  call EnsureDir tgt
  return

StoreExists: procedure
  parse arg tgt, fn
  if IsCms() then return CmsStateFile(fn, tgt)
  return FileExists(tgt || '/' || fn)

StoreCopyIn: procedure
  parse arg src, tgt, fn
  if IsCms() then call CmsCopyIn src, tgt, fn
  else call CopyFile src || '/' || fn, tgt || '/' || fn
  return

StoreDelete: procedure
  parse arg tgt, fn
  if IsCms() then call CmsErase fn, tgt
  else call DelFile tgt || '/' || fn
  return

/* ---- CMS skeleton (VM/370plus, GLOBALV) -------------------------------------
   Records: GLOBALV group RXPIP; per disk <mode> one variable
   REC_<mode> holds the record text with the line ends turned into
   '|' (GLOBALV values are single lines). Names must fit 8.8: a package
   file 'name.type' maps to CMS file NAME TYPE <mode>. */
CmsRecLoad: procedure
  parse arg mode
  address command 'GLOBALV SELECT RXPIP GET REC_' || mode
  v = value('REC_' || mode)
  return translate(v, '0a'x, '|')

CmsRecSave: procedure
  parse arg mode, txt
  v = translate(txt, '|', '0a'x)
  call value 'REC_' || mode, v
  address command 'GLOBALV SELECT RXPIP PUT REC_' || mode
  return

CmsStateFile: procedure
  parse arg fn, mode
  parse var fn name '.' type
  address command 'STATE' name type mode
  return (rc = 0)

CmsCopyIn: procedure
  parse arg src, mode, fn
  parse var fn name '.' type
  /* the package unpacker for VM/370plus puts the files on a work disk;
     'src' then names that disk's filemode */
  address command 'COPYFILE' name type src '=' '=' mode '(REPLACE'
  return

CmsErase: procedure
  parse arg fn, mode
  parse var fn name '.' type
  address command 'ERASE' name type mode
  return

/* ---- registry on top of the record text ---------------------------------- */
InstalledVersion: procedure
  parse arg rec, name
  r = FindInstalledRecord(rec, name)
  if r = '' then return ''
  return StanzaFieldPlain(r, 'VERSION')

FindInstalledRecord: procedure
  parse arg rec, name
  txt = RecLoad(rec)
  cur = ''
  do while txt \= ''
    parse var txt l '0a'x txt
    if l = '' then do
      if cur \= '' & StanzaFieldPlain(cur, 'NAME') = name then return cur
      cur = ''
    end
    else cur = cur || l || '0a'x
  end
  if cur \= '' & StanzaFieldPlain(cur, 'NAME') = name then return cur
  return ''

/* one line per installed package: name 01 version 01 summary */
RecSummary: procedure
  parse arg rec
  txt = RecLoad(rec)
  out = ''
  cur = ''
  do while txt \= ''
    parse var txt l '0a'x txt
    if l = '' then do
      if cur \= '' then out = out || StanzaFieldPlain(cur,'NAME') || '01'x || StanzaFieldPlain(cur,'VERSION') || '01'x || StanzaFieldPlain(cur,'SUMMARY') || '0a'x
      cur = ''
    end
    else cur = cur || l || '0a'x
  end
  if cur \= '' then out = out || StanzaFieldPlain(cur,'NAME') || '01'x || StanzaFieldPlain(cur,'VERSION') || '01'x || StanzaFieldPlain(cur,'SUMMARY') || '0a'x
  return out

RemoveInstalledRecord: procedure
  parse arg rec, name
  txt = RecLoad(rec)
  if txt = '' then return
  out = ''
  cur = ''
  do while txt \= ''
    parse var txt l '0a'x txt
    if l = '' then do
      if cur \= '' & StanzaFieldPlain(cur, 'NAME') \= name then out = out || cur || '0a'x
      cur = ''
    end
    else cur = cur || l || '0a'x
  end
  if cur \= '' & StanzaFieldPlain(cur, 'NAME') \= name then out = out || cur || '0a'x
  call RecSave rec, out
  return

RecordInstalled: procedure
  parse arg rec, name, ver, author, summary, requires, files
  call RemoveInstalledRecord rec, name
  txt = RecLoad(rec)
  txt = txt || 'NAME: ' || name || '0a'x || 'VERSION: ' || ver || '0a'x || 'AUTHOR: ' || author || '0a'x ,
      || 'SUMMARY: ' || summary || '0a'x || 'REQUIRES: ' || requires || '0a'x || 'FILES: ' || files || '0a'x || '0a'x
  call RecSave rec, txt
  return

/* =======================================================================
   CLIENT VERSION, SELF-UPDATE and ADMINISTRATION
   -----------------------------------------------------------------------
   Every request carries X-Rxpip-Client: <kind>/<version> (<os>), which is
   all the server learns about this machine (see the privacy notes in the
   manual). `rxpip update` fetches the newest release of THIS client kind
   from the server and replaces the client files; a once-a-day check
   prints a hint on stderr when a newer release exists (config
   CLIENT_CHECK: off to disable, AUTOUPDATE: 1 to install it silently).
   ======================================================================= */

ClientVersion: procedure
  return '1.4.0'

ClientKind: procedure
  if IsOoRexx() then return 'oorexx'
  return 'regina'

SetClientHeader: procedure expose cfg.
  parse value PlatformTag() with . '-' os '-' .
  if os = '' then os = 'unknown'
  call value 'RXPIP_CLIENT_HDR', 'X-Rxpip-Client: ' || ClientKind() || '/' || ClientVersion() || ' (' || translate(os, 'abcdefghijklmnopqrstuvwxyz', 'ABCDEFGHIJKLMNOPQRSTUVWXYZ') || ')', 'ENVIRONMENT'
  return

ClientHdrArg: procedure
  h = value('RXPIP_CLIENT_HDR',,'ENVIRONMENT')
  if h = '' then return ''
  return '-H "' || h || '"'

/* directory that holds this client's files */
ClientDir: procedure
  d = value('RXPIP_CLIENT_DIR',,'ENVIRONMENT')
  if d \= '' then return translate(d, '/', '\')
  parse source . . src
  return Dirname(translate(src, '/', '\'))

/* the update channel is only trusted over https (or a local test server) */
UpdateChannelOk: procedure
  parse arg repo
  if left(repo, 8) = 'https://' then return 1
  if left(repo, 17) = 'http://127.0.0.1:' | left(repo, 17) = 'http://localhost:' then return 1
  return 0

/* rxpip update [--check] */
CmdUpdate: procedure expose home cfg.
  parse arg args
  rc = DoUpdate(HasFlag(args, '--check'), 0)
  exit rc
  return

/* check (and unless checkonly, install) the newest release. quiet: no
   chatter when already current. Returns 0 ok, 1 failure. */
DoUpdate: procedure expose home cfg.
  parse arg checkonly, quiet
  repo = cfg.REPO_URL
  kind = ClientKind()
  cur = ClientVersion()
  m = ServerGet(repo, 'CLIENT', 'kind=' || kind)
  if StanzaField(m, 'STATUS') \= 'OK' then do
    if \quiet then say 'rxpip: no client release is published for' kind
    return 1
  end
  latest = StanzaField(m, 'VERSION')
  files = StanzaField(m, 'FILES')
  if CompareVersions(latest, cur) <= 0 then do
    if \quiet then say 'rxpip' cur '(' || kind || ') is up to date'
    return 0
  end
  if checkonly then do
    say 'rxpip' latest 'is available (you have' cur || '). Run: rxpip update'
    return 0
  end
  if \UpdateChannelOk(repo) then do
    say 'rxpip: refusing to update over an unencrypted connection (' || repo || ')'
    return 1
  end
  dir = ClientDir()
  say 'rxpip: updating' cur '->' latest 'in' dir
  do i = 1 to words(files)
    f = word(files, i)
    nf = dir || '/' || f || '.new'
    call DelFile nf
    'curl -s -f ' || ClientHdrArg() || ' -o "' || nf || '" "' || repo || '?action=CLIENT&kind=' || kind || '&version=' || latest || '&file=' || UrlEncode(f) || '"'
    ok = 0
    if FileExists(nf) then if stream(nf, 'c', 'query size') > 0 then ok = 1
    if \ok then do
      say 'rxpip: could not download or write' f 'in' dir '(permissions? try again as the owner of that directory)'
      do j = 1 to i
        call DelFile dir || '/' || word(files, j) || '.new'
      end
      return 1
    end
  end
  do i = 1 to words(files)
    call Unblock dir || '/' || word(files, i) || '.new'
  end
  vr = VerifyRelease(dir, files)
  parse var vr vstat vfile
  req = (GetConfigValue(home, 'REQUIRE_SIGNATURE') = '1')
  if vstat = 'FAIL' then do
    say 'rxpip: the signature of' vfile 'is NOT valid -- the update is refused'
  end
  else if vstat \= 'OK' & req then do
    if vstat = 'NOTOOL' then say 'rxpip: REQUIRE_SIGNATURE is set but minisign is not installed -- the update is refused'
    else say 'rxpip: REQUIRE_SIGNATURE is set but this release is not (fully) signed -- the update is refused'
    vstat = 'FAIL'
  end
  if vstat = 'FAIL' then do
    do j = 1 to words(files)
      call DelFile dir || '/' || word(files, j) || '.new'
    end
    return 1
  end
  if vstat = 'NOTOOL' then say 'rxpip: note: signatures not checked (install minisign to check them)'
  if vstat = 'UNSIGNED' then say 'rxpip: note: this release is not signed'
  if vstat = 'OK' then say 'rxpip: signature verified'
  do i = 1 to words(files)
    f = word(files, i)
    call MoveFile dir || '/' || f || '.new', dir || '/' || f
    if \IsWindows() then 'chmod 755 "' || dir || '/' || f || '"'   /* launchers and the shebang script stay executable */
  end
  call StampCheck home, latest, ''
  say 'rxpip: updated to' latest
  return 0

/* Remove the "downloaded from the Internet" mark (Windows Zone.Identifier,
   macOS quarantine) from a file or tree that rxpip itself downloaded or
   unpacked, so that binaries, DLLs and .so files in a package work without
   the user having to unblock them. Never an error. */
Unblock: procedure
  parse arg path
  if IsWindows() then do
    wp = translate(path, '\', '/')
    'dir /s /r "' || wp || '" 2>nul | find ":Zone.Identifier" >nul'
    if rc = 0 then 'powershell -NoProfile -NonInteractive -Command "Get-ChildItem -LiteralPath ''' || wp || ''' -Recurse -Force | Unblock-File" >nul 2>nul'
  end
  else '[ "$(uname -s)" = Darwin ] && xattr -dr com.apple.quarantine "' || path || '" >/dev/null 2>&1; true'
  return

/* the minisign public key that signs the releases */
SignKey: procedure
  k = value('RXPIP_MINISIGN_KEY',,'ENVIRONMENT')
  if k = '' then k = 'RWTwuk9ZuGM56RANzR4KRqK6p6VEGsdcFyB6+vTeRmrlWFWZouyOjcYY'
  return k

/* check the downloaded (.new) files of a release against their .minisig.
   Returns OK, UNSIGNED (a file has no signature), NOTOOL (minisign is not
   installed) or "FAIL <file>" */
VerifyRelease: procedure
  parse arg dir, files
  signed = 0
  unsigned = 0
  do i = 1 to words(files)
    f = word(files, i)
    if right(f, 8) = '.minisig' then iterate
    if wordpos(f || '.minisig', files) > 0 then signed = signed + 1
    else unsigned = unsigned + 1
  end
  if signed = 0 then return 'UNSIGNED'
  'minisign -v >' || NullSink() || ' 2>&1'
  if rc \= 0 then return 'NOTOOL'
  do i = 1 to words(files)
    f = word(files, i)
    if right(f, 8) = '.minisig' | wordpos(f || '.minisig', files) = 0 then iterate
    'minisign -V -q -P ' || SignKey() || ' -m "' || dir || '/' || f || '.new" -x "' || dir || '/' || f || '.minisig.new" >' || NullSink() || ' 2>&1'
    if rc \= 0 then return 'FAIL' f
  end
  if unsigned > 0 then return 'UNSIGNED'
  return 'OK'

StampCheck: procedure
  parse arg home, latest, minv
  f = home || '/clientcheck.txt'
  call DelFile f
  call charout f, 'DATE: ' || date('S') || '0a'x || 'LATEST: ' || latest || '0a'x || 'MIN: ' || minv || '0a'x
  call stream f, 'c', 'close'
  return

/* once a day: look for a newer release and say so on stderr */
CheckClientUpdate: procedure expose home cfg.
  parse arg home
  if translate(GetConfigValue(home, 'CLIENT_CHECK')) = 'OFF' then return
  if value('RXPIP_NO_UPDATE_CHECK',,'ENVIRONMENT') \= '' then return
  f = home || '/clientcheck.txt'
  latest = ''; minv = ''
  if FileExists(f) & FileField(f, 'DATE') = date('S') then do
    latest = FileField(f, 'LATEST'); minv = FileField(f, 'MIN')
  end
  else do
    m = ServerGet(cfg.REPO_URL, 'CLIENT', 'kind=' || ClientKind())
    if StanzaField(m, 'STATUS') = 'OK' then do
      latest = StanzaField(m, 'LATEST'); minv = StanzaField(m, 'MIN')
    end
    call StampCheck home, latest, minv
  end
  cur = ClientVersion()
  if latest = '' | CompareVersions(latest, cur) <= 0 then return
  if GetConfigValue(home, 'AUTOUPDATE') = '1' then do
    if DoUpdate(0, 1) = 0 then do
      call ErrSay 'rxpip: updated to' latest '(run the command again to use it)'
      exit 0
    end
    return
  end
  if minv \= '' & CompareVersions(cur, minv) < 0 then call ErrSay 'rxpip: this client (' || cur || ') is too old for the server (needs' minv || '). Run: rxpip update'
  else call ErrSay 'rxpip: version' latest 'is available (you have' cur || '). Run: rxpip update'
  return

/* a line on standard error (Regina names the stream <stderr>, ooRexx STDERR) */
ErrSay: procedure
  parse arg m
  if IsOoRexx() then call lineout 'STDERR', m
  else call lineout '<stderr>', m
  return

/* a value of key in a "KEY: value" file */
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

/* rxpip admin stats [--days=N] | users | lock <user> |
              client-publish <kind> --version=V [--min=V] <file>... */
CmdAdmin: procedure expose home cfg.
  parse arg sub '01'x rest
  sub = translate(sub)
  repo = cfg.REPO_URL
  t = ResolveToken(home, repo, rest)
  if sub = '' | wordpos(sub, 'STATS USERS LOCK CLIENT-PUBLISH') = 0 then do
    say 'usage: rxpip admin stats [--days=N] | users | lock <user> | client-publish <kind> --version=V [--min=V] <file>...'
    exit 1
    return
  end
  if t = '' then do
    say 'not logged in (rxpip login --token=T)'
    exit 1
    return
  end
  sec = 'X-Rxpip-Token: ' || t
  select
    when sub = 'STATS' then do
      days = OptValue(rest, 'days')
      hdr = ''
      if days \= '' then hdr = 'X-Rxpip-Days: ' || days
      out = ServerPost(repo, 'ADMINSTATS', '', hdr, sec, '')
    end
    when sub = 'USERS' then out = ServerPost(repo, 'ADMINUSERS', '', '', sec, '')
    when sub = 'LOCK' then do
      parse var rest user '01'x .
      if user = '' | left(user, 2) = '--' then do
        say 'usage: rxpip admin lock <user>'
        exit 1
        return
      end
      out = ServerPost(repo, 'ADMINLOCK', '', 'X-Rxpip-User: ' || user, sec, '')
    end
    otherwise do                       /* CLIENT-PUBLISH */
      parse var rest kind '01'x more
      ver = OptValue(more, 'version')
      minv = OptValue(more, 'min')
      dir = ''; names = ''
      do while more \= ''
        parse var more w '01'x more
        if w = '' | left(w, 2) = '--' then iterate
        if \FileExists(w) then do
          say 'rxpip: no such file:' w
          exit 1
          return
        end
        w = translate(w, '/', '\')
        if dir \= '' & Dirname(w) \= dir then do
          say 'rxpip: all release files must be in one directory'
          exit 1
          return
        end
        dir = Dirname(w)
        names = names Basename(w)
      end
      if kind = '' | left(kind, 2) = '--' | ver = '' | names = '' then do
        say 'usage: rxpip admin client-publish <kind> --version=V [--min=V] <file>...'
        exit 1
        return
      end
      tgz = TempDir() || '/rxpip_rel_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tgz'
      'tar czf "' || tgz || '" -C "' || dir || '" ' || names
      hdr = 'X-Rxpip-Kind: ' || kind || '01'x || 'X-Rxpip-Version: ' || ver
      if minv \= '' then hdr = hdr || '01'x || 'X-Rxpip-Min: ' || minv
      out = ServerPost(repo, 'ADMINCLIENT', '', hdr, sec, tgz)
      call DelFile tgz
    end
  end
  rc = ShowResponse(out)
  exit rc
  return

/* =======================================================================
   HTTP TRANSPORT  (shells out to curl; text responses read back in full)
   ======================================================================= */

/* GET <repo_url>?action=X&<extra>  ->  full response body (text) */
ServerGet: procedure expose cfg.
  parse arg repo, action, extra
  url = repo || '?action=' || action
  if extra \= '' then url = url || '&' || extra
  tmp = TempDir() || '/rxpip_resp_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  hf = ReadHeaderFile()
  if hf = '' then 'curl -s --connect-timeout 15 ' || ClientHdrArg() || ' -o "' || tmp || '" "' || url || '"'
  else do
    'curl -s --connect-timeout 15 ' || ClientHdrArg() || ' -o "' || tmp || '" -H @"' || hf || '" "' || url || '"'
    call DelFile hf
  end
  out = ''
  if FileExists(tmp) then do
    do while lines(tmp) > 0
      out = out || linein(tmp) || '0a'x
    end
    call stream tmp, 'c', 'close'
  end
  call DelFile tmp
  return out

/* a private temporary header file carrying the token for a read request
   (private packages), or '' when there is no token. The token never goes
   on a command line or in a URL. */
ReadHeaderFile: procedure expose cfg.
  if cfg.READTOKEN = '' then return ''
  return MakeSecretFile('X-Rxpip-Token: ' || cfg.READTOKEN)

MakeSecretFile: procedure
  parse arg secrets
  hdrfile = TempDir() || '/rxpip_hdr_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
  if IsWindows() then do
    call charout hdrfile, translate(secrets, '0a'x, '01'x) || '0d0a'x
    call stream hdrfile, 'c', 'close'
  end
  else do
    call value 'RXPIP_SECRET_HDRS', translate(secrets, '0a'x, '01'x), 'ENVIRONMENT'
    '(umask 077; printf "%s\n" "$RXPIP_SECRET_HDRS" > "' || hdrfile || '")'
    call value 'RXPIP_SECRET_HDRS', '', 'ENVIRONMENT'
  end
  return hdrfile

/* download one specific artifact (kind/platform) to outfile; 0 on success */
ServerDownload: procedure expose cfg.
  parse arg repo, name, ver, kind, platform, outfile
  url = repo || '?action=DOWNLOAD&name=' || UrlEncode(name)
  if ver \= '' then url = url || '&version=' || UrlEncode(ver)
  url = url || '&kind=' || UrlEncode(kind) || '&platform=' || UrlEncode(platform)
  hf = ReadHeaderFile()
  if hf = '' then 'curl -s -f ' || ClientHdrArg() || ' -o "' || outfile || '" "' || url || '"'
  else do
    'curl -s -f ' || ClientHdrArg() || ' -o "' || outfile || '" -H @"' || hf || '" "' || url || '"'
    call DelFile hf
  end
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
  uniq = translate(time('L'), '__', ':.') || '_' || random(1,99999)
  hdrfile = MakeSecretFile(secrets)
  tmp = TempDir() || '/rxpip_post_' || uniq || '.tmp'
  cmd = 'curl -s ' || ClientHdrArg() || ' -o "' || tmp || '" -X POST -H @"' || hdrfile || '"'
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
  parse arg repo, pkgfile, name, ver, author, summary, requires, kind, platform, token, vis
  hdrs = 'X-Rxpip-Name: ' || name || '01'x ||,
         'X-Rxpip-Version: ' || ver || '01'x ||,
         'X-Rxpip-Author: ' || author || '01'x ||,
         'X-Rxpip-Summary: ' || summary || '01'x ||,
         'X-Rxpip-Requires: ' || requires || '01'x ||,
         'X-Rxpip-Kind: ' || kind || '01'x ||,
         'X-Rxpip-Platform: ' || platform
  if vis \= '' then hdrs = hdrs || '01'x || 'X-Rxpip-Visibility: ' || vis
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
  if StanzaField(out, 'STATUS') = 'OK' then return 0
  return 1

/* =======================================================================
   TEXT / STANZA UTILITIES
   ======================================================================= */

/* This machine's artifact-selection tag: <interpreter>-<os>-<arch>,
   e.g. "regina-linux-x86_64". Used to prefer an exact BYTECODE
   artifact when one has been published; SOURCE/any always matches
   as the universal fallback (see server's artifact-model note). */
PlatformTag: procedure expose cfg.
  interp = Interpreter()
  if IsOS2() then do
    os = 'os2'
    arch = 'x86'
  end
  else if IsWindows() then do
    /* no shell-out needed -- Windows sets these env vars itself */
    os = 'windows'
    arch = translate(value('PROCESSOR_ARCHITECTURE',,'ENVIRONMENT'))
    if arch = 'AMD64' then arch = 'x86_64'
    else if arch = 'ARM64' then arch = 'arm64'
    else if arch = '' then arch = 'x86_64'
  end
  else do
    tmp = TempDir() || '/rxpip_uname_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
    'uname -s > "' || tmp || '"'
    os = ''
    if FileExists(tmp) then do
      os = translate(strip(linein(tmp)))
      call stream tmp, 'c', 'close'
    end
    call DelFile tmp
    tmp = TempDir() || '/rxpip_arch_' || translate(time('L'), '__', ':.') || '_' || random(1,99999) || '.tmp'
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
      if translate(curP) = translate(platformtag) & translate(curK) \= 'NATIVE' then ,
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
HasFlag: procedure
  parse arg args, flag
  return pos('01'x || flag || '01'x, '01'x || args || '01'x) > 0

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

/* OS/2 (and ArcaOS, ROSE): IsWindows() is true there too (COMSPEC, CMD.EXE,
   backslashes); the helpers below take OS/2 branches where OS/2's CMD differs
   from Windows' (no /Y, /Q, /D, no parenthesised groups, MKDIR one level) */
IsOS2: procedure
  parse source os .
  return (translate(os) = 'OS/2')

/* RexxUtil, for the OS/2 file helpers */
LoadUtil: procedure
  if RxFuncQuery('SysLoadFuncs') then do
    call RxFuncAdd 'SysLoadFuncs', 'RexxUtil', 'SysLoadFuncs'
    call SysLoadFuncs
  end
  return

TempDir: procedure
  if IsWindows() then do
    t = value('TEMP',,'ENVIRONMENT')
    if t = '' then t = value('TMP',,'ENVIRONMENT')
    if t = '' & IsOS2() then t = left(directory(), 2)   /* the current drive's root */
    if t = '' then t = 'C:/Windows/Temp'
    return translate(t, '/', '\')
  end
  return '/tmp'

NullSink: procedure
  if IsWindows() then return 'nul'
  return '/dev/null'

DelFile: procedure
  parse arg f
  if IsOS2() then 'del "' || translate(f,'\','/') || '" >nul 2>nul'
  else if IsWindows() then 'del /f /q "' || translate(f,'\','/') || '" >nul 2>nul'
  else 'rm -f "' || f || '"'
  return

DelTree: procedure
  parse arg d
  if IsOS2() then call OS2DelTree translate(d,'\','/')
  else if IsWindows() then 'rmdir /s /q "' || translate(d,'\','/') || '" >nul 2>nul'
  else 'rm -rf "' || d || '"'
  return

MoveFile: procedure
  parse arg src, dst
  if IsOS2() then do      /* OS/2's MOVE neither replaces nor crosses drives */
    call CopyFile src, dst
    call DelFile src
  end
  else if IsWindows() then 'move /y "' || translate(src,'\','/') || '" "' || translate(dst,'\','/') || '" >nul'
  else 'mv "' || src || '" "' || dst || '"'
  return

CopyFile: procedure
  parse arg src, dst
  if IsOS2() then 'copy "' || translate(src,'\','/') || '" "' || translate(dst,'\','/') || '" >nul 2>nul'
  else if IsWindows() then 'copy /y "' || translate(src,'\','/') || '" "' || translate(dst,'\','/') || '" >nul' ,
                       '2>nul'
  else 'cp "' || src || '" "' || dst || '"' '2>/dev/null'
  return

EnsureDir: procedure
  parse arg d
  if IsOS2() then do      /* MKDIR makes one level */
    w = translate(d,'\','/')
    p = 0
    do forever
      p = pos('\', w, p + 1)
      if p = 0 then leave
      if p > 1 & substr(w, p - 1, 1) \= ':' then 'mkdir "' || left(w, p - 1) || '" >nul 2>nul'
    end
    'mkdir "' || strip(w, 'T', '\') || '" >nul 2>nul'
  end
  else if IsWindows() then 'mkdir "' || translate(d,'\','/') || '" 2>nul'
  else 'mkdir -p "' || d || '"'
  return

/* run a command with dir as the working directory; returns its RC
   (isolated procedures don't share RC with their caller in REXX, so
   this must be captured and returned explicitly rather than left for
   the caller to read RC after the CALL) */
/* interpreter used to run programs: RXPIP_INTERPRETER (set by the ooRexx
   launcher) beats the shared config.txt setting */
Interpreter: procedure expose cfg.
  i = value('RXPIP_INTERPRETER',,'ENVIRONMENT')
  if i = '' then i = cfg.INTERPRETER
  if i = '' then i = 'regina'
  return i

IsOoRexx: procedure
  parse version v
  return pos('ooRexx', v) > 0

/* split a command line made of double-quoted arguments into '01'x-terminated
   tokens. mode 1: \" and \\ are escapes inside quotes; mode 2: no escapes */
SplitQuoted: procedure
  parse arg s, mode
  out = ''
  cur = ''
  inq = 0
  has = 0
  i = 1
  do while i <= length(s)
    c = substr(s, i, 1)
    if inq then do
      if mode = 1 & c = '\' & i < length(s) then do
        i = i + 1
        cur = cur || substr(s, i, 1)
      end
      else if c = '"' then inq = 0
      else cur = cur || c
    end
    else if c = '"' then do
      inq = 1
      has = 1
    end
    else if c = ' ' | c = '09'x then do
      if has | cur \= '' then do
        out = out || cur || '01'x
        cur = ''
        has = 0
      end
    end
    else cur = cur || c
    i = i + 1
  end
  if has | cur \= '' then out = out || cur || '01'x
  return out

RunInDir: procedure
  parse arg dir, cmdline
  if IsOS2() then do      /* no CD /D: change the drive, then the directory */
    wd = translate(dir,'\','/')
    if substr(wd, 2, 1) = ':' then 'cd "' || wd || '" && ' || left(wd, 2) || ' && ' || cmdline
    else 'cd "' || wd || '" && ' || cmdline
    return rc
  end
  if IsWindows() then 'cd /d "' || translate(dir,'\','/') || '" && ' || cmdline
  else 'cd "' || dir || '" && ' || cmdline
  return rc

/* delete a directory tree with RexxUtil (OS/2's RMDIR has no /S) */
OS2DelTree: procedure
  parse arg d
  call LoadUtil
  call SysFileTree d || '\*', 'f.', 'FSO'
  do i = 1 to f.0
    call SysFileDelete f.i
  end
  call SysFileTree d || '\*', 's.', 'DSO'
  do i = s.0 to 1 by -1      /* deepest first */
    call SysRmDir s.i
  end
  call SysRmDir d
  return

Bomb:
  if value("RXPIP_DEBUG",,"ENVIRONMENT") \= "" then say "DEBUG:" sigl sourceline(sigl)
  say 'rxpip: internal error at line' sigl':' errortext(rc)
  exit 1
