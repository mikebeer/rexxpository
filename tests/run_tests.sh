#!/usr/bin/env bash
# End-to-end tests for the RXPIP server (and, later sections, the client).
# Starts a CGI harness that behaves like Apache (forwards all headers, runs
# the script as the current user), then drives it over real HTTP with curl.
#
#   tests/run_tests.sh            run everything
#   PORT=8099 tests/run_tests.sh  use another port
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PORT=${PORT:-8089}
WORK=$(mktemp -d)
REPO=$WORK/repo
BASE=http://127.0.0.1:$PORT/cgi-bin/rxpip_server.rexx
PASS=0
FAIL=0
mkdir -p "$REPO"

cleanup() { [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

python3 "$ROOT/tests/cgi_harness.py" --port "$PORT" \
  --script "$ROOT/server/rxpip_server.rexx" --repo "$REPO" &
HPID=$!
for _ in $(seq 1 50); do
  curl -s "$BASE?action=PING" 2>/dev/null | grep -q "STATUS: OK" && break
  sleep 0.1
done

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; }
# expect <description> <haystack> <needle>
expect() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "wanted [$3] in: $(printf '%s' "$2" | head -c 300)"; fi; }
expect_not() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1" "did not want [$3]"; else ok "$1"; fi; }
section() { echo; echo "== $1"; }

# --- fixtures ---------------------------------------------------------------
FX=$WORK/fx; mkdir -p "$FX"
cp "$ROOT"/examples/mathutils/mathutils.rexx "$FX/"
cp "$ROOT"/examples/strutils/strutils.rexx "$FX/"
cp "$ROOT"/examples/greetutils/greetutils.rexx "$FX/"
tar czf "$WORK/mathutils.rxpkg" -C "$FX" mathutils.rexx
tar czf "$WORK/strutils.rxpkg" -C "$FX" strutils.rexx
tar czf "$WORK/greetutils.rxpkg" -C "$FX" greetutils.rexx
tar czf "$WORK/dotslash.rxpkg" -C "$FX" ./mathutils.rexx
TOKA=tokenAAAA_0123456789abcdef
TOKB=tokenBBBB_0123456789abcdef

# pub <name> <ver> <token> <file> [extra curl args...]  -> sets BODY and CODE
pub() {
  local name=$1 ver=$2 tok=$3 file=$4; shift 4
  local out
  out=$(curl -s -w '\n%{http_code}' -X POST \
        -H "X-Rxpip-Name: $name" -H "X-Rxpip-Version: $ver" \
        -H "X-Rxpip-Author: tester" -H "X-Rxpip-Summary: a test package" \
        -H "X-Rxpip-Token: $tok" "$@" --data-binary @"$file" "$BASE?action=PUBLISH")
  CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
}
get() { curl -s "$BASE?$1"; }

# ============================================================================
section "baseline"
expect "PING answers" "$(get action=PING)" "STATUS: OK"
expect "empty repo lists zero packages" "$(get action=LIST)" "COUNT: 0"

# ============================================================================
section "step 1: token handling"
pub mathutils 1.0.0 "$TOKA" "$WORK/mathutils.rxpkg"
expect "publish with header token succeeds" "$BODY" "MESSAGE: published"
[ "$CODE" = 200 ] && ok "publish returns HTTP 200" || bad "publish returns HTTP 200" "got $CODE"

OWNER=$(cat "$REPO/.auth/mathutils.owner" 2>/dev/null)
expect "owner record is a salted sha256 record" "$OWNER" 'sha256$'
expect_not "plaintext token is not stored" "$OWNER" "$TOKA"
expect_not "plaintext token is not anywhere in the repo" "$(grep -r "$TOKA" "$REPO" 2>/dev/null)" "$TOKA"

out=$(curl -s -w '\n%{http_code}' -X POST -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-Version: 1.0.1" \
      -H "X-Rxpip-Token: $TOKA" --data-binary @"$WORK/mathutils.rxpkg" "$BASE?action=PUBLISH&token=$TOKA")
expect "token in URL is refused" "$out" "TOKEN_IN_URL"
expect "token in URL gives HTTP 400" "$out" "400"
[ -d "$REPO/mathutils/1.0.1" ] && bad "refused upload wrote nothing" "1.0.1 exists" || ok "refused upload wrote nothing"

pub mathutils 1.0.2 "$TOKB" "$WORK/mathutils.rxpkg"
expect "wrong token is forbidden" "$BODY" "FORBIDDEN"
[ "$CODE" = 403 ] && ok "wrong token gives HTTP 403" || bad "wrong token gives HTTP 403" "got $CODE"

pub mathutils 1.0.2 "short" "$WORK/mathutils.rxpkg"
expect "short token is rejected" "$BODY" "BAD_TOKEN"
[ "$CODE" = 401 ] && ok "short token gives HTTP 401" || bad "short token gives HTTP 401" "got $CODE"

out=$(curl -s -w '\n%{http_code}' -X POST -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-Version: 1.0.2" \
      --data-binary @"$WORK/mathutils.rxpkg" "$BASE?action=PUBLISH")
expect "missing token is rejected" "$out" "NO_TOKEN"

# ============================================================================
section "step 1: immutability and artifacts"
cp "$REPO/mathutils/1.0.0/artifacts/SOURCE-ANY.rxpkg" "$WORK/before.rxpkg"
pub mathutils 1.0.0 "$TOKA" "$WORK/strutils.rxpkg"
expect "re-publishing an existing artifact is refused" "$BODY" "ALREADY_EXISTS"
[ "$CODE" = 409 ] && ok "conflict gives HTTP 409" || bad "conflict gives HTTP 409" "got $CODE"
cmp -s "$WORK/before.rxpkg" "$REPO/mathutils/1.0.0/artifacts/SOURCE-ANY.rxpkg" \
  && ok "existing artifact bytes untouched" || bad "existing artifact bytes untouched"

pub mathutils 1.0.0 "$TOKA" "$WORK/strutils.rxpkg" -H "X-Rxpip-Kind: BYTECODE" -H "X-Rxpip-Platform: crexx-linux-x86_64" -H "X-Rxpip-Summary: DIFFERENT"
expect "a second artifact kind for the same version is accepted" "$BODY" "MESSAGE: published"
expect "differing metadata is not applied" "$BODY" "NOTE:"
expect "version metadata kept from first artifact" "$(get 'action=INFO&name=mathutils&version=1.0.0')" "SUMMARY: a test package"
[ "$(grep -c '^NAME:' "$REPO/mathutils/1.0.0/PACKAGE.META")" = 1 ] \
  && ok "PACKAGE.META is not duplicated" || bad "PACKAGE.META is not duplicated"
expect "ARTIFACTS lists both" "$(get 'action=ARTIFACTS&name=mathutils&version=1.0.0')" "COUNT: 2"
curl -s -o "$WORK/dl.rxpkg" "$BASE?action=DOWNLOAD&name=mathutils&version=1.0.0"
cmp -s "$WORK/before.rxpkg" "$WORK/dl.rxpkg" && ok "download is byte-identical to upload" || bad "download is byte-identical to upload"
code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE?action=DOWNLOAD&name=mathutils&version=9.9.9")
[ "$code" = 404 ] && ok "download of missing artifact gives HTTP 404" || bad "download of missing artifact gives HTTP 404" "got $code"

pub dotslash 1.0.0 "$TOKA" "$WORK/dotslash.rxpkg"
expect "archive members with ./ prefix are normalised" "$(get 'action=ARTIFACTS&name=dotslash')" "FILES: mathutils.rexx"

# ============================================================================
section "step 1: upload size cap"
head -c 6000000 /dev/urandom > "$WORK/huge.bin"
pub bigpkg 1.0.0 "$TOKA" "$WORK/huge.bin"
expect "6 MB upload exceeds the default cap" "$BODY" "TOO_LARGE"
[ "$CODE" = 413 ] && ok "oversize gives HTTP 413" || bad "oversize gives HTTP 413" "got $CODE"
[ -e "$REPO/.auth/bigpkg.owner" ] && bad "oversize upload does not claim the name" || ok "oversize upload does not claim the name"

# ============================================================================
section "step 1: input validation"
out=$(curl -s -w '\n%{http_code}' -X POST -H "X-Rxpip-Token: $TOKA" --data-binary @"$WORK/mathutils.rxpkg" \
      "$BASE?action=PUBLISH&name=injected&version=1.0.0&summary=nice%0AREQUIRES:%20evil")
expect "newline in summary is rejected (field injection)" "$out" "BAD_METADATA"
out=$(curl -s -w '\n%{http_code}' -X POST -H "X-Rxpip-Token: $TOKA" --data-binary @"$WORK/mathutils.rxpkg" \
      "$BASE?action=PUBLISH&name=injected&version=1.0.0&requires=a%0AFILES:%20x")
expect "newline in requires is rejected" "$out" "BAD_REQUIRES"
pub injected 1.0.0 "$TOKA" "$WORK/mathutils.rxpkg" -H "X-Rxpip-Requires: good>=1.0 ; rm -rf /"
expect "malformed requires is rejected" "$BODY" "BAD_REQUIRES"
pub "../evil" 1.0.0 "$TOKA" "$WORK/mathutils.rxpkg"
expect "path traversal in name is rejected" "$BODY" "BAD_NAME"
pub okname "1.0/../x" "$TOKA" "$WORK/mathutils.rxpkg"
expect "bad version is rejected" "$BODY" "BAD_VERSION"
expect "INFO rejects traversal in version" "$(get 'action=INFO&name=mathutils&version=..%2F..')" "BAD_VERSION"
expect "ARTIFACTS rejects traversal in version" "$(get 'action=ARTIFACTS&name=mathutils&version=..%2F..')" "BAD_VERSION"
expect "DOWNLOAD rejects traversal in version" "$(get 'action=DOWNLOAD&name=mathutils&version=..%2F..')" "BAD_VERSION"
out=$(curl -s -w '\n%{http_code}' -X POST -H "X-Rxpip-Name: emptyone" -H "X-Rxpip-Version: 1.0.0" -H "X-Rxpip-Token: $TOKA" "$BASE?action=PUBLISH")
expect "empty body is rejected" "$out" "EMPTY_BODY"

# ============================================================================
section "step 1: archive validation"
python3 - "$WORK" << 'EOF'
import io, os, sys, tarfile
w = sys.argv[1]
def make(name, members):
    with tarfile.open(os.path.join(w, name), "w:gz") as t:
        for m in members:
            t.addfile(*m)
def reg(name, data=b"say 'x'\n"):
    ti = tarfile.TarInfo(name); ti.size = len(data); return (ti, io.BytesIO(data))
def sym(name, target):
    ti = tarfile.TarInfo(name); ti.type = tarfile.SYMTYPE; ti.linkname = target; return (ti, None)
def dirm(name):
    ti = tarfile.TarInfo(name); ti.type = tarfile.DIRTYPE; ti.mode = 0o755; return (ti, None)
make("evil_symlink.rxpkg", [reg("a.rexx"), sym("b.rexx", "/etc/passwd")])
make("evil_dotdot.rxpkg", [reg("../../outside.rexx")])
make("evil_abs.rxpkg", [reg("/tmp/abs.rexx")])
make("evil_nested.rxpkg", [reg("sub/dir.rexx")])
make("evil_dir.rxpkg", [dirm("sub"), reg("a.rexx")])
make("evil_name.rxpkg", [reg("bad name;rm.rexx")])
make("evil_hidden.rxpkg", [reg(".hidden")])
make("empty.rxpkg", [])
open(os.path.join(w, "notgzip.rxpkg"), "wb").write(b"this is not an archive at all\n" * 20)
EOF
for t in evil_symlink evil_dotdot evil_abs evil_nested evil_dir evil_name evil_hidden empty notgzip; do
  pub archtest 1.0.0 "$TOKA" "$WORK/$t.rxpkg"
  expect "archive '$t' is rejected" "$BODY" "BAD_ARCHIVE"
done
[ -e "$REPO/.auth/archtest.owner" ] && bad "rejected archives do not claim the name" || ok "rejected archives do not claim the name"
[ -e "$REPO/archtest" ] && bad "rejected archives leave no package directory behind" "$(find "$REPO/archtest")" || ok "rejected archives leave no package directory behind"
[ -z "$(find "$REPO/.staging" -type f 2>/dev/null)" ] && ok "staging area is empty after rejections" || bad "staging area is empty after rejections" "$(find "$REPO/.staging" -type f)"
expect "ghost packages do not appear in LIST" "$(get action=LIST)" "COUNT: 2"

# ============================================================================
section "step 1: concurrent first publish of one name"
( pub racepkg 1.0.0 "$TOKA" "$WORK/mathutils.rxpkg"; echo "$CODE" > "$WORK/race1" ) &
RP1=$!
( pub racepkg 1.0.0 "$TOKB" "$WORK/mathutils.rxpkg"; echo "$CODE" > "$WORK/race2" ) &
RP2=$!
wait $RP1 $RP2
r1=$(cat "$WORK/race1"); r2=$(cat "$WORK/race2")
if { [ "$r1" = 200 ] && [ "$r2" != 200 ]; } || { [ "$r2" = 200 ] && [ "$r1" != 200 ]; }; then
  ok "exactly one racer wins the name ($r1/$r2)"
else
  bad "exactly one racer wins the name" "got $r1 and $r2"
fi

# ============================================================================
section "step 1: client publish / install / run (real client over HTTP)"
CH=$WORK/clienthome
export RXPIP_HOME=$CH
mkdir -p "$CH"
RX="regina -a $ROOT/client/rxpip.rexx"
$RX config set REPO_URL "$BASE" >/dev/null 2>&1
CTOK=clienttoken_0123456789abcdef
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.0 --token=$CTOK --summary="client test" 2>&1)
expect "client publish succeeds" "$out" "STATUS: OK"
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.1 --token=short 2>&1)
expect "client rejects short token locally" "$out" "16-128"
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.2 --token=wrongtoken_0123456789abc 2>&1)
expect "client shows server FORBIDDEN for wrong token" "$out" "FORBIDDEN"
out=$(RXPIP_TOKEN=$CTOK $RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.3 2>&1)
expect "client takes token from RXPIP_TOKEN" "$out" "STATUS: OK"
grep -rq "$CTOK" "$REPO" && bad "client token never stored in clear on server" || ok "client token never stored in clear on server"
out=$($RX install cligreet 2>&1)
expect "client install works" "$out" "cligreet"
ls /tmp 2>/dev/null | grep -q rxpip_hdr_ && bad "token header file removed" || ok "token header file removed"
unset RXPIP_HOME

# ============================================================================
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
