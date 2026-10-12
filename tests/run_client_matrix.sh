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
      printf '/* lib1 */\nTwice: procedure\n  parse arg n\n  return n * 2\n' > "$d/lib1.rexx"
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
      regina|oorexx) tar czf lib1.rxpkg lib1.rexx; tar czf lib2.rxpkg lib2.rexx ;;
      netrexx) tar czf lib1.rxpkg Lib1Nx.nrx; tar czf lib2.rxpkg Lib2Nx.nrx ;;
      crexx) tar czf lib1.rxpkg lib1cx.crexx; tar czf lib2.rxpkg lib2cx.crexx ;;
    esac )
}

run_client() {
  local c=$1 RX plat d
  RX=$(client_cmd "$c")
  if [ -z "$RX" ]; then SKIP="$SKIP $c"; echo; echo "== client: $c  (skipped: not available here)"; return; fi
  echo; echo "== client: $c"
  plat=$(platform_of "$c")
  make_fixtures "$c"; d=$WORK/fx_$c
  export RXPIP_HOME=$WORK/home_$c; mkdir -p "$RXPIP_HOME"
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
  out=$(cd "$d" && $RX run "$PROG" 2>&1);       expect "run compiles/uses the packages" "$out" "$WANT_RUN"
  out=$(cd "$d" && $RX run "$ARGP" "one two" three 2>&1)
  expect "run forwards an argument with a space" "$out" "= [one two]"
  expect "run forwards the next argument" "$out" "= [three]"
  out=$($RX scan "$PROG" 2>&1);                 expect "scan reads REQUIRE" "$out" "already installed"
  out=$($RX uninstall m2$c 2>&1);               expect "uninstall" "$out" "removed m2$c"
  out=$($RX list 2>&1);                         expect_not "uninstalled package is gone" "$out" "m2$c"
  out=$($RX uninstall nonesuch 2>&1);           expect "uninstall unknown" "$out" "not installed"
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
  $RX logout >/dev/null 2>&1
  out=$($RX whoami 2>&1);                       expect "whoami after logout" "$out" "not logged in"
  ls /tmp 2>/dev/null | grep -q rxpip_hdr_ && bad "no token header file left behind" || ok "no token header file left behind"
  grep -rq "rxp_" "$REPO" 2>/dev/null && bad "server never stores a clear token" || ok "server never stores a clear token"
  unset RXPIP_HOME
}

for c in ${CLIENTS:-regina oorexx netrexx crexx}; do run_client "$c"; done

# ---- cross-client: classic packages are shared between Regina and ooRexx ------
if [ -z "${CLIENTS:-}" ] && [ -n "$(client_cmd regina)" ] && [ -n "$(client_cmd oorexx)" ]; then
  echo; echo "== cross-client: Regina and ooRexx share one package store"
  export RXPIP_HOME=$WORK/home_shared; mkdir -p "$RXPIP_HOME"
  R=$(client_cmd regina); O=$(client_cmd oorexx)
  $R config set REPO_URL "$BASE" >/dev/null 2>&1
  expect "Regina installs the classic package" "$($R install m1regina 2>&1)" "installing m1regina"
  expect "ooRexx sees it as installed" "$($O list 2>&1)" "m1regina"
  expect "ooRexx will not reinstall it" "$($O install m1regina 2>&1)" "already installed"
  unset RXPIP_HOME
fi

echo
[ -n "$SKIP" ] && echo "skipped (not installed here):$SKIP"
echo "client matrix  passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
