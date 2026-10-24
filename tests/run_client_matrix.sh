#!/usr/bin/env bash
# Runs the same client scenario against every RXPIP client that can run on
# this machine (Regina, ooRexx, NetRexx, cREXX), against one CGI harness.
#
#   tests/run_client_matrix.sh                 all available clients
#   CLIENTS="regina netrexx" tests/run_client_matrix.sh
#   NETREXX_JAR=/path/NetRexxC.jar  (NetRexx),  CREXX_HOME or rxc on PATH (cREXX)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${PORT:-8091}
WORK=$(mktemp -d)
REPO=$WORK/repo
BASE=http://127.0.0.1:$PORT/cgi-bin/rxpip_server.rexx
PASS=0; FAIL=0; SKIP=""
mkdir -p "$REPO"
unset JAVA_TOOL_OPTIONS
cleanup() { [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export RXPIP_SCANNER=off   # no virus scanner in the test environment
python3 "$ROOT/tests/cgi_harness.py" --port "$PORT" --script "$ROOT/server/rxpip_server.rexx" --repo "$REPO" &
HPID=$!
for _ in $(seq 1 50); do curl -s "$BASE?action=PING" 2>/dev/null | grep -q "STATUS: OK" && break; sleep 0.1; done

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
expect() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "wanted [$3] in: $(printf '%s' "$2" | head -c 400)"; fi; }
expect_not() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "did not want [$3]"; else ok "$1"; fi; }
adm() { RXPIP_REPO_ROOT="$REPO" regina -a "$ROOT/server/rxpip_server.rexx" admin "$@"; }

# ---- which clients exist here -----------------------------------------------
client_cmd() {  # prints the command line for a client, or nothing if unavailable
  case $1 in
    regina)  command -v regina >/dev/null && echo "regina -a $ROOT/client/rxpip.rexx" ;;
    oorexx)  command -v rexx >/dev/null && rexx -v 2>&1 | grep -qi oorexx && echo "$ROOT/client/oorexx/rxpip-oorexx" ;;
    netrexx) command -v java >/dev/null && [ -f "${NETREXX_JAR:-/nonexistent}" ] && echo "$ROOT/client/netrexx/rxpip-netrexx" ;;
    crexx)   { command -v rxc >/dev/null || [ -x "${CREXX_HOME:-/nonexistent}/bin/rxc" ]; } && echo "$ROOT/client/crexx/rxpip-crexx" ;;
  esac
}
platform_of() { case $1 in netrexx) echo netrexx;; crexx) echo crexx;; *) echo any;; esac; }

# ---- per-language fixtures: lib1 (Twice), lib2 (requires lib1), program ------
make_fixtures() {  # $1 = client name ; creates $WORK/fx_$1/{lib1.rxpkg,lib2.rxpkg,prog.*}
  local c=$1 d=$WORK/fx_$1; mkdir -p "$d"
  case $c in
    regina|oorexx)
      printf '/* lib1 */\nTwice: procedure\n  parse arg n\n  return n * 2\n' > "$d/lib1.rex"   # .rex: Windows users often have this extension
      printf '/* lib2 */\nThrice: procedure\n  parse arg n\n  return n * 3\n' > "$d/lib2.rexx"
      printf '/* REQUIRE m1%s */\nsay "result" Twice(21)\n' "$c" > "$d/prog.rexx"
      printf '/* args */\ndo i = 1 to arg()\n  say "arg" i "= [" || arg(i) || "]"\nend\n/* REQUIRE m1%s */\n' "$c" > "$d/argp.rexx"
      PROG=$d/prog.rexx; ARGP=$d/argp.rexx; WANT_RUN="result 42" ;;
    netrexx)
      printf 'class Lib1Nx\n  method twice(n=int) static returns int\n    return n * 2\n' > "$d/Lib1Nx.nrx"
      printf 'class Lib2Nx\n  method thrice(n=int) static returns int\n    return n * 3\n' > "$d/Lib2Nx.nrx"
      printf '/* REQUIRE m1netrexx */\nclass prog\n  method main(a=String[]) static\n    say "result" Lib1Nx.twice(21)\n    loop i = 0 to a.length - 1\n      say "arg" (i + 1) "= [" || a[i] || "]"\n    end\n' > "$d/prog.nrx"
      PROG=$d/prog.nrx; ARGP=$d/prog.nrx; WANT_RUN="result 42" ;;
    crexx)
      printf 'options levelb\nnamespace lib1cx expose twice\nimport rxfnsb\ntwice: procedure = .int\n  arg n = .int\n  return n * 2\n' > "$d/lib1cx.crexx"
      printf 'options levelb\nnamespace lib2cx expose thrice\nimport rxfnsb\nthrice: procedure = .int\n  arg n = .int\n  return n * 3\n' > "$d/lib2cx.crexx"
      printf '/* REQUIRE m1crexx */\noptions levelb\nimport rxfnsb\nimport lib1cx\narg a = .string[]\nsay "result" twice(21)\ndo i = 1 to a.0\n  say "arg" i "= [" || a[i] || "]"\nend\nreturn 0\n' > "$d/prog.crexx"
      PROG=$d/prog.crexx; ARGP=$d/prog.crexx; WANT_RUN="result 42" ;;
  esac
  ( cd "$d" && case $c in
      regina|oorexx) tar czf lib1.rxpkg lib1.rex; tar czf lib2.rxpkg lib2.rexx ;;
      netrexx) tar czf lib1.rxpkg Lib1Nx.nrx; tar czf lib2.rxpkg Lib2Nx.nrx ;;
      crexx) tar czf lib1.rxpkg lib1cx.crexx; tar czf lib2.rxpkg lib2cx.crexx ;;
    esac )
}

# ---- native artifacts: platform/ABI selection, system prerequisites, plugins ----
native_tests() {
  local RX=$1 n=$WORK/native; mkdir -p "$n/src/doc" "$n/nat/providers" "$n/nat/libs" "$n/nat/share" "$n/cxh/bin"
  local tag; tag=$($RX platform | head -1)
  expect "platform prints the tag" "$tag" "crexx-"
  printf 'options levelb\nnamespace gtkpkg expose gtkversion\nimport rxfnsb\ngtkversion: procedure = .string\n  return "4.10"\n' > "$n/src/gtkpkg.crexx"
  echo docs > "$n/src/doc/README.md"
  head -c 3000 /dev/urandom > "$n/nat/providers/libfakeprov.so"; head -c 2000 /dev/urandom > "$n/nat/libs/libglue.so"; echo data > "$n/nat/share/x.xml"
  tar czf "$n/src.rxpkg" -C "$n/src" gtkpkg.crexx doc; tar czf "$n/nat.rxpkg" -C "$n/nat" providers libs share
  local out
  pubn() { $RX publish "$@" 2>&1; }
  # only a build for another platform
  pubn "$n/src.rxpkg" --name=npa --version=1.0.0 >/dev/null
  pubn "$n/nat.rxpkg" --name=npa --version=1.0.0 --kind=NATIVE --platform=crexx-windows-x86_64 --abi=rxpa1 >/dev/null
  mkdir -p "$n/c1"; out=$(cd "$n/c1" && $RX install npa 2>&1; echo "rc=$?")
  expect "no native build for this system: refused" "$out" "has native builds only for crexx-windows-x86_64/rxpa1"
  expect "the message names this system" "$out" "this system is $tag"
  expect "the refusal is a non-zero exit" "$out" "rc=1"
  if [ -z "$(ls "$n/c1")" ]; then ok "nothing is installed on refusal"; else bad "nothing is installed on refusal" "$(ls "$n/c1")"; fi
  out=$(cd "$n/c1" && $RX install npa --no-native 2>&1); expect "--no-native installs the source only" "$out" "SOURCE/crexx)"
  # unsupported ABI
  pubn "$n/src.rxpkg" --name=npb --version=1.0.0 >/dev/null
  pubn "$n/nat.rxpkg" --name=npb --version=1.0.0 --kind=NATIVE --abi=rxpa9 >/dev/null
  mkdir -p "$n/c2"; out=$(cd "$n/c2" && $RX install npb 2>&1)
  expect "an unsupported ABI is refused" "$out" "with ABI rxpa1"
  out=$(cd "$n/c2" && RXPIP_ABI=rxpa9 $RX install npb 2>&1); expect "RXPIP_ABI selects another interface level" "$out" "NATIVE/$tag"
  # missing system prerequisites
  pubn "$n/src.rxpkg" --name=npc --version=1.0.0 >/dev/null
  pubn "$n/nat.rxpkg" --name=npc --version=1.0.0 --kind=NATIVE --abi=rxpa1 --runtime-requires="cmd:sh cmd:no-such-tool-xyz lib:nosuchlibxyz" >/dev/null
  mkdir -p "$n/c3"; out=$(cd "$n/c3" && $RX install npc 2>&1; echo "rc=$?")
  expect "a missing program is named" "$out" "cmd:no-such-tool-xyz (program not found)"
  expect "a missing library is named" "$out" "lib:nosuchlibxyz (library not found)"
  expect_not "a present program is not reported" "$out" "cmd:sh ("
  expect "missing prerequisites give a non-zero exit" "$out" "rc=1"
  if [ -z "$(ls "$n/c3")" ]; then ok "nothing is installed when prerequisites are missing"; else bad "nothing is installed when prerequisites are missing" "$(ls "$n/c3")"; fi
  out=$(cd "$n/c3" && $RX install npc --skip-runtime-check 2>&1); expect "--skip-runtime-check installs anyway" "$out" "installing npc"
  # a good package: install, check, run, build
  pubn "$n/src.rxpkg" --name=gtkpkg --version=1.0.0 >/dev/null
  out=$(pubn "$n/nat.rxpkg" --name=gtkpkg --version=1.0.0 --kind=NATIVE --abi=rxpa1 --runtime-requires="cmd:sh" --build-requires="cmd:sh")
  expect "the native artifact defaults to this platform" "$out" "PLATFORM: $tag"
  mkdir -p "$n/c4"; out=$(cd "$n/c4" && $RX install gtkpkg 2>&1)
  expect "source and native build are installed together" "$out" "SOURCE/crexx + NATIVE/$tag"
  if [ -f "$n/c4/gtkpkg.crexx" ] && [ ! -e "$n/c4/README.md" ]; then ok "only the source module goes to the install directory"; else bad "only the source module goes to the install directory" "$(ls -a "$n/c4")"; fi
  local pd; pd=$(find "$RXPIP_HOME" -path "*pkgs/gtkpkg/1.0.0" -type d | head -1)
  if cmp -s "$pd/providers/libfakeprov.so" "$n/nat/providers/libfakeprov.so" && cmp -s "$pd/libs/libglue.so" "$n/nat/libs/libglue.so" && [ -f "$pd/share/x.xml" ]; then ok "plugin, library and data are in the package directory"; else bad "plugin, library and data are in the package directory" "$(find "$pd" | head)"; fi
  expect "the record keeps platform and ABI" "$(cat "$n/c4/.rxpip/installed.txt")" "NATIVE: $tag rxpa1"
  expect "the record keeps the runtime requirements" "$(cat "$n/c4/.rxpip/installed.txt")" "RUNTIME-REQUIRES: cmd:sh"
  out=$(cd "$n/c4" && $RX check 2>&1); expect "check passes when everything is there" "$out" "all system prerequisites"
  # run: a logging rxvm stands in for the VM so the hand-over can be seen
  cat > "$n/cxh/bin/rxvm" <<VMEOF
#!/bin/sh
echo "ARGS: \$*" > $n/vm.log
echo "LD: \$LD_LIBRARY_PATH" >> $n/vm.log
echo "PKG: \$RXPIP_PKG_GTKPKG" >> $n/vm.log
exec $(command -v rxvm) "\$@"
VMEOF
  chmod +x "$n/cxh/bin/rxvm"
  printf '/* REQUIRE gtkpkg */\noptions levelb\nimport rxfnsb\nimport gtkpkg\nsay "gtk" gtkversion()\nreturn 0\n' > "$n/app.crexx"
  out=$(cd "$n" && CREXX_HOME="$n/cxh" $RX run app.crexx 2>&1)
  expect "run works with a native package" "$out" "gtk 4.10"
  local vm; vm=$(cat "$n/vm.log")
  expect "run passes the providers to the VM" "$vm" "--provider-path $pd/providers"
  expect "run puts the libraries on the search path" "$vm" "LD: $pd/libs"
  expect "run exports the package directory" "$vm" "PKG: $pd"
  out=$(cd "$n" && CREXX_HOME="$n/cxh" $RX build app.crexx --output="$n/out" 2>&1)
  expect "build carries the native files along" "$out" "copied to $n/out/pkgs"
  expect "build lists the external prerequisites" "$out" "external prerequisites rxpip does not ship (install on the target system): cmd:sh"
  if [ -f "$n/out/pkgs/gtkpkg/providers/libfakeprov.so" ] && [ -f "$n/out/pkgs/gtkpkg/libs/libglue.so" ] && [ -f "$n/out/pkgs/gtkpkg/share/x.xml" ]; then ok "build output contains plugin, library and data"; else bad "build output contains plugin, library and data" "$(find "$n/out" -type f)"; fi
  out=$(cd "$n/out" && CREXX_HOME="$n/cxh" ./run.sh one 2>&1); expect "the built run script starts the program" "$out" "gtk 4.10"
  vm=$(cat "$n/vm.log")
  expect "the run script passes the providers" "$vm" "--provider-path $n/out/pkgs/gtkpkg/providers"
  expect "the run script forwards arguments" "$vm" "-a one"
  expect "the run script sets the library path" "$vm" "LD: $n/out/pkgs/gtkpkg/libs"
  # a prerequisite that disappears after the install is caught at run time
  printf 'options levelb\nnamespace gonepkg\nimport rxfnsb\n' > "$n/src/gonepkg.crexx"
  tar czf "$n/gone.rxpkg" -C "$n/src" gonepkg.crexx
  pubn "$n/gone.rxpkg" --name=gtkgone --version=1.0.0 >/dev/null
  pubn "$n/nat.rxpkg" --name=gtkgone --version=1.0.0 --kind=NATIVE --abi=rxpa1 --runtime-requires="cmd:no-such-tool-xyz" >/dev/null
  (cd "$n/c4" && $RX install gtkgone --global --skip-runtime-check >/dev/null 2>&1)
  printf '/* REQUIRE gtkgone */\noptions levelb\nimport rxfnsb\nsay "x"\nreturn 0\n' > "$n/app2.crexx"
  out=$(cd "$n" && $RX run app2.crexx 2>&1)
  expect "run refuses when a prerequisite is missing" "$out" "'gtkgone' needs system prerequisites: cmd:no-such-tool-xyz"
}

run_client() {
  local c=$1 RX plat d
  RX=$(client_cmd "$c")
  if [ -z "$RX" ]; then SKIP="$SKIP $c"; echo; echo "== client: $c  (skipped: not available here)"; return; fi
  echo; echo "== client: $c"
  plat=$(platform_of "$c")
  make_fixtures "$c"; d=$WORK/fx_$c
  export RXPIP_HOME=$WORK/home_$c; mkdir -p "$RXPIP_HOME"
  local cwd=$WORK/cwd_$c; mkdir -p "$cwd"; cd "$cwd"      # installs go to the current directory
  local out inv user=u$c
  out=$($RX config set REPO_URL "$BASE" 2>&1); expect "config set" "$out" "set REPO_URL"
  out=$($RX list 2>&1);                         expect "empty list" "$out" "(no packages installed)"
  inv=$(adm invite "matrix $c" | sed -n 's/^invite code.*: //p')
  out=$($RX register --user=$user --invite=$inv 2>&1)
  expect "register with invite" "$out" "registered as $user"
  expect_not "register output hides the token" "$out" "rxp_"
  [ "$(stat -c %a "$RXPIP_HOME/credentials.txt" 2>/dev/null)" = 600 ] && ok "credentials file is mode 600" || bad "credentials file is mode 600" "$(stat -c %a "$RXPIP_HOME/credentials.txt" 2>&1)"
  out=$($RX whoami 2>&1);                       expect "whoami" "$out" "USER: $user"
  out=$($RX register --user=${user}x --invite=$inv 2>&1); expect "used invite is refused" "$out" "BAD_INVITE"
  out=$($RX publish "$d/lib1.rxpkg" --name=m1$c --version=1.0.0 --summary="lib one" --platform=$plat 2>&1)
  expect "publish lib1" "$out" "published"
  out=$($RX publish "$d/lib1.rxpkg" --name=m1$c --version=1.0.0 --platform=$plat 2>&1)
  expect "republishing the same version is refused" "$out" "STATUS: ERROR"
  out=$($RX publish "$d/lib2.rxpkg" --name=m2$c --version=1.0.0 --requires="m1$c>=1.0.0" --platform=$plat 2>&1)
  expect "publish lib2 with a requirement" "$out" "published"
  out=$($RX search m1$c 2>&1);                  expect "search finds it" "$out" "m1$c"
  out=$($RX show m1$c 2>&1);                    expect "show" "$out" "VERSION: 1.0.0"
  out=$($RX install m2$c 2>&1)
  expect "install m2" "$out" "installing m2$c"
  expect "dependency is installed too" "$out" "installing m1$c"
  out=$($RX list 2>&1)
  expect "list shows lib1" "$out" "m1$c"; expect "list shows lib2" "$out" "m2$c"
  out=$($RX freeze 2>&1);                       expect "freeze" "$out" "m1$c==1.0.0"
  out=$($RX install m1$c 2>&1);                 expect "second install is a no-op" "$out" "already installed"
  out=$($RX publish "$d/lib1.rxpkg" --name=m1$c --version=1.0.1 --platform=$plat 2>&1); expect "publish 1.0.1" "$out" "published"
  out=$($RX install m1$c 2>&1);                 expect "plain install does not upgrade" "$out" "1.0.0 already installed"
  out=$($RX install --upgrade m1$c 2>&1);       expect "--upgrade installs the newer version" "$out" "installing m1$c 1.0.1"
  out=$($RX freeze 2>&1);                       expect "freeze shows the new version" "$out" "m1$c==1.0.1"
  out=$($RX install -U m1$c 2>&1);              expect "-U on the newest version does nothing" "$out" "1.0.1 already installed"
  out=$(cd "$d" && $RX run "$PROG" 2>&1);       expect "run compiles/uses the packages" "$out" "$WANT_RUN"
  out=$(cd "$d" && $RX run "$ARGP" "one two" three 2>&1)
  expect "run forwards an argument with a space" "$out" "= [one two]"
  expect "run forwards the next argument" "$out" "= [three]"
  if [ "$plat" = any ]; then
    out=$(cd "$d" && $RX build "$PROG" --output="$d/built.out" 2>&1); expect "build with REQUIRE lines writes a program" "$out" "wrote self-contained program"
    grep -q "Twice" "$d/built.out" && ok "the built program contains the package" || bad "the built program contains the package" "$(head -5 "$d/built.out")"
  fi
  out=$($RX scan "$PROG" 2>&1);                 expect "scan reads REQUIRE" "$out" "already installed"
  out=$($RX uninstall m2$c 2>&1);               expect "uninstall" "$out" "removed m2$c"
  out=$($RX list 2>&1);                         expect_not "uninstalled package is gone" "$out" "m2$c"
  out=$($RX uninstall nonesuch 2>&1);           expect "uninstall unknown" "$out" "not installed"
  [ "$($RX freeze 2>&1 | grep -c "^m1$c==")" = 1 ] && ok "one record per package after an upgrade" || bad "one record per package after an upgrade" "$($RX freeze 2>&1)"
  out=$($RX uninstall m1$c 2>&1);               expect "uninstalling the last package works" "$out" "removed m1$c"
  out=$($RX list 2>&1);                         expect "list is empty after the last uninstall" "$out" "(no packages installed)"
  out=$($RX install m1$c==1.0.1 2>&1);          expect "installing again into an empty store" "$out" "installing m1$c 1.0.1"
  out=$($RX install m1$c==1.0.0 2>&1);          expect "a lower == version is satisfied by the newer install" "$out" "1.0.1 already installed"
  # ---- scope: current directory (default), --global, --target, find ----
  local f1; f1=$(tar tzf "$d/lib1.rxpkg" | head -1)
  [ -f "$cwd/$f1" ] && ok "package file is in the current directory" || bad "package file is in the current directory" "$(ls -a "$cwd")"
  [ -f "$cwd/.rxpip/installed.txt" ] && ok "record is kept in ./.rxpip" || bad "record is kept in ./.rxpip" "$(ls -a "$cwd")"
  out=$($RX list --global 2>&1);                expect "--global list is a separate store" "$out" "m1$c"
  expect_not "the shared store has no m2" "$out" "m2$c"
  local other_dir=$WORK/other_$c; mkdir -p "$other_dir"
  out=$(cd "$other_dir" && $RX list 2>&1);      expect "another directory starts empty" "$out" "(no packages installed)"
  out=$($RX install --target "$other_dir" m1$c==1.0.0 2>&1); expect "--target installs elsewhere" "$out" "installing m1$c 1.0.0"
  [ -f "$other_dir/$f1" ] && ok "--target puts the files there" || bad "--target puts the files there" "$(ls -a "$other_dir")"
  out=$($RX find "$cwd" "$other_dir" 2>&1);     expect "find lists both installs" "$out" "$other_dir"
  expect "find flags the older copy" "$out" "older than 1.0.1"
  out=$($RX find --sync "$cwd" "$other_dir" 2>&1); expect "find --sync updates it" "$out" "updating m1$c"
  out=$($RX list --target "$other_dir" 2>&1);   expect "the older copy is now current" "$out" "1.0.1"
  out=$($RX find "$cwd" "$other_dir" 2>&1);     expect_not "nothing outdated after --sync" "$out" "older than"
  local clash=$WORK/clash_$c; mkdir -p "$clash"; echo "mine" > "$clash/$f1"
  out=$($RX install --target "$clash" m1$c 2>&1); expect "an existing foreign file is not overwritten" "$out" "not installed by rxpip"
  [ "$(cat "$clash/$f1")" = mine ] && ok "the foreign file is untouched" || bad "the foreign file is untouched" "$(cat "$clash/$f1")"
  out=$($RX install --force --target "$clash" m1$c 2>&1); expect "--force overwrites" "$out" "installing m1$c"
  out=$($RX uninstall --target "$clash" m1$c 2>&1); expect "uninstall --target" "$out" "removed m1$c"
  out=$($RX uninstall --target "$other_dir" m1$c 2>&1); expect "uninstall in the other directory" "$out" "removed m1$c"
  [ -f "$other_dir/$f1" ] && bad "uninstall removes the files" "still there" || ok "uninstall removes the files"
  # ---- private packages ----
  local anon=$WORK/anon_$c; mkdir -p "$anon"
  RXPIP_HOME=$anon $RX config set REPO_URL "$BASE" >/dev/null 2>&1
  out=$($RX publish "$d/lib2.rxpkg" --name=priv$c --version=1.0.0 --platform=$plat --private 2>&1); expect "publish --private" "$out" "published"
  out=$($RX search priv$c 2>&1);                expect "the owner finds the private package" "$out" "priv$c"
  out=$($RX show priv$c 2>&1);                  expect "show says private" "$out" "VISIBILITY: private"
  out=$(RXPIP_HOME=$anon $RX search priv$c 2>&1); expect_not "anonymous search does not find it" "$out" "priv$c"
  out=$(RXPIP_HOME=$anon $RX install priv$c 2>&1); expect "anonymous install cannot resolve it" "$out" "cannot resolve"
  out=$($RX install --target "$WORK/privdir_$c" priv$c 2>&1); expect "the owner installs it" "$out" "installing priv$c"
  out=$($RX visibility priv$c public 2>&1);     expect "visibility public" "$out" "VISIBILITY: public"
  out=$(RXPIP_HOME=$anon $RX search priv$c 2>&1); expect "now anonymous search finds it" "$out" "priv$c"
  out=$($RX visibility priv$c private 2>&1);    expect "visibility private" "$out" "VISIBILITY: private"
  out=$($RX reader list priv$c 2>&1);           expect "reader list" "$out" "VISIBILITY: private"
  out=$(RXPIP_HOME=$anon $RX visibility priv$c public 2>&1); expect "anonymous cannot change visibility" "$out" "not logged in"
  out=$($RX install doesnotexist 2>&1);         expect "install unknown" "$out" "cannot resolve"
  out=$($RX install "m1$c>=9.0.0" 2>&1);        expect ">= on an old install reports the problem" "$out" "needs version >=9.0.0"
  out=$($RX token new --label=ci 2>&1);         expect "token new" "$out" "TOKEN: rxp_"
  local nid; nid=$(printf '%s' "$out" | sed -n 's/^TOKEN: rxp_\([0-9a-f]*\)_.*/\1/p')
  out=$($RX token list 2>&1);                   expect "token list" "$out" "COUNT: 2"
  out=$($RX token revoke "$nid" 2>&1);          expect "token revoke" "$out" "revoked"
  out=$($RX owner list m1$c 2>&1);              expect "owner list" "$out" "OWNERS: $user"
  # the other-language artifact must not install here
  local other=netrexx; [ "$c" = netrexx ] && other=crexx
  if [ "$plat" != any ]; then
    out=$($RX publish "$d/lib1.rxpkg" --name=wrongplat$c --version=1.0.0 --platform=$other 2>&1)
    out=$($RX install wrongplat$c 2>&1);        expect "other-language artifact is not installed" "$out" "no compatible artifact"
  fi
  # ---- version check, self-update and the administrator commands ----
  local ccdir=$WORK/cc_$c relsrc rname
  cp -r "$ROOT/client" "$ccdir"
  local RX2=${RX/$ROOT\/client/$ccdir}
  case $c in regina|oorexx) relsrc=$ccdir/rxpip.rexx;; netrexx) relsrc=$ccdir/netrexx/Rxpip.nrx;; crexx) relsrc=$ccdir/crexx/rxpip.crexx;; esac
  rname=$(basename "$relsrc")
  out=$($RX2 update --check 2>&1);              expect "update --check without a release" "$out" "no client release"
  out=$($RX admin stats 2>&1);                  expect "a normal user cannot read the statistics" "$out" "FORBIDDEN"
  adm addadmin $user >/dev/null
  out=$($RX admin stats --days=2 2>&1);         expect "an administrator reads the statistics" "$out" "REQUESTS:"
  expect "the statistics show this client kind" "$out" " $c "
  out=$($RX admin users 2>&1);                  expect "admin users" "$out" "USER: $user"
  mkdir -p "$WORK/rel_$c"; cp "$relsrc" "$WORK/rel_$c/"; echo '/* UPDATED-MARK */' >> "$WORK/rel_$c/$rname"
  out=$($RX admin client-publish $c --version=99.0.0 --min=1.0.0 "$WORK/rel_$c/$rname" 2>&1); expect "client-publish" "$out" "LATEST: 99.0.0"
  out=$($RX2 update --check 2>&1);              expect "update --check sees the new release" "$out" "99.0.0 is available"
  rm -f "$RXPIP_HOME/clientcheck.txt"
  out=$($RX2 search nothingatall 2>&1);         expect "the daily hint is shown" "$out" "version 99.0.0 is available"
  out=$(RXPIP_NO_UPDATE_CHECK=1 $RX2 search nothingatall 2>&1); expect_not "and can be switched off" "$out" "is available"
  grep -q UPDATED-MARK "$relsrc" && bad "client is untouched before update" "already updated" || ok "client is untouched before update"
  out=$($RX2 update 2>&1);                      expect "update installs the new release" "$out" "updated to 99.0.0"
  grep -q UPDATED-MARK "$relsrc" && ok "the client file was replaced" || bad "the client file was replaced" "$(tail -2 "$relsrc")"
  [ -f "$relsrc.new" ] && bad "no temporary file left behind" "$relsrc.new" || ok "no temporary file left behind"
  [ -x "$relsrc" ] && ok "updated files stay executable" || bad "updated files stay executable" "$(ls -l "$relsrc")"
  # ---- signed releases (needs the minisign program) ----
  if command -v minisign >/dev/null 2>&1; then
    local MK=$WORK/mk_$c; mkdir -p "$MK/r2" "$MK/r3"
    minisign -G -W -f -p "$MK/t.pub" -s "$MK/t.key" >/dev/null 2>&1
    export RXPIP_MINISIGN_KEY=$(sed -n 2p "$MK/t.pub")
    cp "$relsrc" "$MK/r2/"; echo '/* SIGNED-OK */' >> "$MK/r2/$rname"
    minisign -S -s "$MK/t.key" -m "$MK/r2/$rname" -x "$MK/r2/$rname.minisig" >/dev/null 2>&1
    out=$($RX admin client-publish $c --version=99.1.0 "$MK/r2/$rname" "$MK/r2/$rname.minisig" 2>&1); expect "publish a signed release" "$out" "$rname.minisig"
    out=$($RX2 update 2>&1);                    expect "a signed release is verified" "$out" "signature verified"
    grep -q SIGNED-OK "$relsrc" && ok "the verified release was installed" || bad "the verified release was installed" "$(tail -2 "$relsrc")"
    [ -f "$(dirname "$relsrc")/$rname.minisig" ] && ok "the signature is kept next to the file" || bad "the signature is kept next to the file"
    cp "$relsrc" "$MK/r3/"; minisign -S -s "$MK/t.key" -m "$MK/r3/$rname" -x "$MK/r3/$rname.minisig" >/dev/null 2>&1
    echo '/* TAMPERED */' >> "$MK/r3/$rname"
    out=$($RX admin client-publish $c --version=99.2.0 "$MK/r3/$rname" "$MK/r3/$rname.minisig" 2>&1); expect "publish a release whose file does not match its signature" "$out" "LATEST: 99.2.0"
    out=$($RX2 update 2>&1);                    expect "a bad signature is refused" "$out" "NOT valid"
    grep -q TAMPERED "$relsrc" && bad "the tampered file was not installed" "installed" || ok "the tampered file was not installed"
    [ -f "$relsrc.new" ] && bad "no temporary file left after a refused update" || ok "no temporary file left after a refused update"
    unset RXPIP_MINISIGN_KEY
  else
    echo "  (minisign not installed: signed-release tests skipped)"
  fi
  out=$($RX admin lock nobody 2>&1);            expect "admin lock of an unknown user" "$out" "NO_SUCH_USER"
  # ---- likes (recommendations) ----
  out=$($RX like m1$c 2>&1);                    expect "you cannot recommend your own package" "$out" "OWN_PACKAGE"
  out=$($RX like 2>&1);                         expect "like without a name shows usage" "$out" "usage: rxpip like"
  local liker; liker=$(adm adduser liker$c | sed 's/.*: //')
  out=$(RXPIP_TOKEN=$liker $RX like m1$c 2>&1); expect "another user recommends it" "$out" "LIKES: 1"
  expect "and is told so" "$out" "LIKED: yes"
  out=$($RX show m1$c 2>&1);                    expect "show displays the count" "$out" "LIKES: 1"
  out=$($RX search m1$c 2>&1);                  expect "search displays the count" "$out" "LIKES: 1"
  out=$($RX search --sort=likes m1$c 2>&1);     expect "search --sort=likes works" "$out" "m1$c"
  out=$(RXPIP_TOKEN=$liker $RX unlike m1$c 2>&1); expect "unlike takes it back" "$out" "LIKES: 0"

  # ---- package directories (subdirectories inside a package) ----
  local ext top
  case $c in netrexx) ext=nrx;; crexx) ext=crexx;; *) ext=rexx;; esac
  local td=$WORK/tree_$c; mkdir -p "$td/p/doc" "$td/p/share/data"
  case $c in
    netrexx) printf 'class TreeMod%s\n  method hi static returns Rexx\n    return "hi"\n' "$c" > "$td/p/TreeMod$c.nrx"; top=TreeMod$c.nrx ;;
    crexx)   printf 'options levelb\nnamespace treemod\nimport rxfnsb\n' > "$td/p/treemod.crexx"; top=treemod.crexx ;;
    *)       printf '/* tree */\nTreeHi: procedure\n  return "hi"\n' > "$td/p/treehi.rexx"; top=treehi.rexx ;;
  esac
  echo "readme of $c" > "$td/p/doc/README.md"
  head -c 5000 /dev/urandom > "$td/p/share/data/blob.bin"
  tar czf "$td/tree.rxpkg" -C "$td/p" "$top" doc share
  out=$($RX publish "$td/tree.rxpkg" --name=t1$c --version=1.0.0 --platform=$plat 2>&1)
  expect "a package with subdirectories is published" "$out" "published"
  local tcwd=$WORK/treecwd_$c; mkdir -p "$tcwd"
  out=$(cd "$tcwd" && $RX install t1$c 2>&1); expect "it installs" "$out" "installing t1$c"
  [ -f "$tcwd/$top" ] && ok "the top-level file lands in the install directory" || bad "the top-level file lands in the install directory" "$(ls -a "$tcwd")"
  if [ -e "$tcwd/README.md" ] || [ -e "$tcwd/doc" ] || [ -e "$tcwd/blob.bin" ]; then bad "nested files are not flattened into the install directory" "$(ls -a "$tcwd")"; else ok "nested files are not flattened into the install directory"; fi
  local nd; nd=$(find "$RXPIP_HOME" -path "*pkgs/t1$c/1.0.0/doc/README.md" | head -1)
  [ -n "$nd" ] && ok "the package directory keeps the tree" || bad "the package directory keeps the tree" "$(find "$RXPIP_HOME" -path "*t1$c*" | head)"
  local bd; bd=$(find "$RXPIP_HOME" -path "*pkgs/t1$c/1.0.0/share/data/blob.bin" | head -1)
  if [ -n "$bd" ] && cmp -s "$bd" "$td/p/share/data/blob.bin"; then ok "a binary data file survives byte-identical"; else bad "a binary data file survives byte-identical"; fi
  out=$(cd "$tcwd" && $RX uninstall t1$c 2>&1); expect "it uninstalls" "$out" "removed t1$c"
  if [ -f "$tcwd/$top" ]; then bad "uninstall removes the top-level file"; else ok "uninstall removes the top-level file"; fi

  # ---- native artifacts (cREXX client) ----
  if [ "$c" = crexx ]; then native_tests "$RX"; fi

  $RX logout >/dev/null 2>&1
  out=$($RX whoami 2>&1);                       expect "whoami after logout" "$out" "not logged in"
  ls /tmp 2>/dev/null | grep -q rxpip_hdr_ && bad "no token header file left behind" || ok "no token header file left behind"
  grep -rq "rxp_" "$REPO" 2>/dev/null && bad "server never stores a clear token" || ok "server never stores a clear token"
  cd "$ROOT"; unset RXPIP_HOME
}

for c in ${CLIENTS:-regina oorexx netrexx crexx}; do run_client "$c"; done

# ---- cross-client: classic packages are shared between Regina and ooRexx ------
if [ -z "${CLIENTS:-}" ] && [ -n "$(client_cmd regina)" ] && [ -n "$(client_cmd oorexx)" ]; then
  echo; echo "== cross-client: Regina and ooRexx share one package store"
  export RXPIP_HOME=$WORK/home_shared; mkdir -p "$RXPIP_HOME"
  R=$(client_cmd regina); O=$(client_cmd oorexx)
  mkdir -p "$WORK/cwd_shared"; cd "$WORK/cwd_shared"
  $R config set REPO_URL "$BASE" >/dev/null 2>&1
  expect "Regina installs the classic package" "$($R install m1regina 2>&1)" "installing m1regina"
  expect "ooRexx sees it as installed" "$($O list 2>&1)" "m1regina"
  expect "ooRexx will not reinstall it" "$($O install m1regina 2>&1)" "already installed"
  cd "$ROOT"; unset RXPIP_HOME
fi

echo
[ -n "$SKIP" ] && echo "skipped (not installed here):$SKIP"
echo "client matrix  passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
