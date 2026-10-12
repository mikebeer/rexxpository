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
# users are created with the server's own admin mode (the only way in)
adm() { RXPIP_REPO_ROOT=$REPO regina -a "$ROOT/server/rxpip_server.rexx" admin "$@"; }
TOKA=$(adm adduser alice | sed 's/.*: //')
TOKB=$(adm adduser bob | sed 's/.*: //')

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

OWNER=$(cat "$REPO"/.auth/tokens/*.tok 2>/dev/null)
expect "token records are salted sha256 records" "$OWNER" 'sha256$'
expect_not "plaintext token is not stored" "$OWNER" "$TOKA"
expect "owner list names the publishing user" "$(cat "$REPO/.auth/owners/mathutils.owners")" "alice"
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
[ -e "$REPO/.auth/owners/bigpkg.owners" ] && bad "oversize upload does not claim the name" || ok "oversize upload does not claim the name"

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
[ -e "$REPO/.auth/owners/archtest.owners" ] && bad "rejected archives do not claim the name" || ok "rejected archives do not claim the name"
[ -e "$REPO/archtest" ] && bad "rejected archives leave no package directory behind" "$(find "$REPO/archtest")" || ok "rejected archives leave no package directory behind"
[ -z "$(find "$REPO/.staging" -type f 2>/dev/null)" ] && ok "staging area is empty after rejections" || bad "staging area is empty after rejections" "$(find "$REPO/.staging" -type f)"
expect "ghost packages do not appear in LIST" "$(get action=LIST)" "COUNT: 2"

# ============================================================================
section "step 3: read-only web frontend"
H() { curl -si "$@"; }
curl -s -o /dev/null -X POST -H "X-Rxpip-Name: webpkg" -H "X-Rxpip-Version: 1.2.0" -H "X-Rxpip-Author: <b>Ann</b> & co" \
  -H "X-Rxpip-Summary: <script>alert(1)</script> \"quoted\" 'single'" -H "X-Rxpip-Requires: mathutils>=1.0.0" \
  -H "X-Rxpip-Token: $TOKA" --data-binary @"$WORK/strutils.rxpkg" "$BASE?action=PUBLISH"
curl -s -o /dev/null -X POST -H "X-Rxpip-Name: webpkg" -H "X-Rxpip-Version: 1.3.0" -H "X-Rxpip-Summary: newer" \
  -H "X-Rxpip-Token: $TOKA" --data-binary @"$WORK/strutils.rxpkg" "$BASE?action=PUBLISH"
page=$(H "$BASE")
expect "index is served as HTML" "$page" "Content-Type: text/html"
expect "index lists packages" "$page" ">mathutils</a>"
expect "index shows the latest version" "$page" "<td>1.3.0</td>"
expect "index links to the package page" "$page" "action=PKG&amp;name=webpkg"
expect "CSP forbids scripts" "$page" "Content-Security-Policy: default-src 'none'"
expect "nosniff header set" "$page" "X-Content-Type-Options: nosniff"
expect_not "no script elements in the page" "$page" "<script"
expect "search finds by name" "$(H "$BASE?q=webp")" ">webpkg</a>"
expect_not "search excludes non-matches" "$(H "$BASE?q=webp")" ">mathutils</a>"
expect "search echoes the term escaped" "$(H "$BASE?q=%3Cb%3E")" "No packages found"
expect_not "search term is not reflected raw" "$(H "$BASE?q=%3Cscript%3E")" "<script>"
pk=$(H "$BASE?action=PKG&name=webpkg&version=1.2.0")
expect "package page: HTTP 200" "$pk" "200 OK"
expect "package page: summary is HTML-escaped" "$pk" "&lt;script&gt;alert(1)&lt;/script&gt; &quot;quoted&quot; &#39;single&#39;"
expect_not "package page: no raw script tag from metadata" "$pk" "<script>alert"
expect "package page: author is escaped" "$pk" "&lt;b&gt;Ann&lt;/b&gt; &amp; co"
expect "package page: install command" "$pk" "rxpip install webpkg==1.2.0"
expect "package page: owners shown" "$pk" "alice"
expect "package page: requires is linked" "$pk" "action=PKG&amp;name=mathutils"
expect "package page: points to the newer version" "$pk" "View 1.3.0"
expect "package page: download link" "$pk" "action=DOWNLOAD&amp;name=webpkg&amp;version=1.2.0&amp;kind=SOURCE&amp;platform=any"
expect "package page: version list" "$pk" "version=1.3.0"
dl=$(printf '%s' "$pk" | grep -o 'href="[^"]*action=DOWNLOAD[^"]*"' | head -1 | sed 's/^href="//; s/"$//; s/&amp;/\&/g')
curl -s -o "$WORK/webdl.rxpkg" "http://127.0.0.1:$PORT$dl"
cmp -s "$WORK/webdl.rxpkg" "$WORK/strutils.rxpkg" && ok "the download link on the page serves the artifact" || bad "the download link on the page serves the artifact" "link=$dl"
expect "latest version is the default" "$(H "$BASE?action=PKG&name=webpkg")" "<h1>webpkg <span class=\"mute\">1.3.0"
expect "unknown package gives 404" "$(H "$BASE?action=PKG&name=nonesuch")" "404 Not Found"
expect "unsafe name gives 400" "$(H "$BASE?action=PKG&name=../etc")" "400 Bad Request"
expect "bad version gives 400" "$(H "$BASE?action=PKG&name=webpkg&version=1/../x")" "400 Bad Request"
expect "the frontend exposes no token material" "$(printf '%s' "$page$pk")" "rexxpository"
expect_not "no token or hash in any page" "$(printf '%s' "$page$pk")" "sha256$"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE")
[ "$code" = 200 ] && ok "POST to the index is harmless" || bad "POST to the index is harmless" "got $code"

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
section "step 2: invites and registration"
# api <action> <token> [extra curl args]  -> BODY, CODE   (POST, token in header)
api() {
  local act=$1 tok=$2; shift 2
  local out
  out=$(curl -s -w '\n%{http_code}' -X POST ${tok:+-H "X-Rxpip-Token: $tok"} "$@" "$BASE?action=$act")
  CODE=${out##*$'\n'}; BODY=${out%$'\n'*}
}
INV1=$(adm invite first | sed 's/.*: //; s/ .*//' | head -1)
expect "invite code has the inv_ shape" "$INV1" "inv_"
api REGISTER "" -H "X-Rxpip-Invite: $INV1" -H "X-Rxpip-User: carol"
expect "registration with a valid invite succeeds" "$BODY" "STATUS: OK"
TOKC=$(printf '%s\n' "$BODY" | sed -n 's/^TOKEN: //p')
expect "registration returns a token" "$TOKC" "rxp_"
expect "register response is not cacheable" "$(curl -si -X POST -H "X-Rxpip-Invite: nope" -H "X-Rxpip-User: dave" "$BASE?action=REGISTER" | head -1)" "403"
api REGISTER "" -H "X-Rxpip-Invite: $INV1" -H "X-Rxpip-User: dave"
expect "an invite cannot be used twice" "$BODY" "BAD_INVITE"
[ "$CODE" = 403 ] && ok "used invite gives HTTP 403" || bad "used invite gives HTTP 403" "got $CODE"
INV2=$(adm invite second | sed 's/.*: //; s/ .*//' | head -1)
api REGISTER "" -H "X-Rxpip-Invite: $INV2" -H "X-Rxpip-User: carol"
expect "duplicate username is refused" "$BODY" "USER_EXISTS"
api REGISTER "" -H "X-Rxpip-Invite: $INV2" -H "X-Rxpip-User: Bad Name"
expect "invalid username is refused" "$BODY" "BAD_USER"
api REGISTER "" -H "X-Rxpip-Invite: $INV2" -H "X-Rxpip-User: Carol"
expect "uppercase username is refused (case-insensitive FS safety)" "$BODY" "BAD_USER"
api REGISTER "" -H "X-Rxpip-Invite: inv_00000000_00000000000000000000000000000000" -H "X-Rxpip-User: erin"
expect "forged invite is refused" "$BODY" "BAD_INVITE"
api REGISTER "" -H "X-Rxpip-Invite: $INV2" -H "X-Rxpip-User: dave"
expect "the unused invite still works after failed attempts" "$BODY" "STATUS: OK"
expect_not "invite secret is not stored in clear" "$(grep -r "${INV1##*_}" "$REPO/.auth" 2>/dev/null)" "${INV1##*_}"
expect_not "token secret is not stored in clear" "$(grep -r "${TOKC##*_}" "$REPO/.auth" 2>/dev/null)" "${TOKC##*_}"
r1=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "X-Rxpip-Invite: $INV2" -H "X-Rxpip-User: frank" "$BASE?action=REGISTER")
INV3=$(adm invite race | sed 's/.*: //; s/ .*//' | head -1)
( api REGISTER "" -H "X-Rxpip-Invite: $INV3" -H "X-Rxpip-User: racer1"; echo "$CODE" > "$WORK/ri1" ) &
RI1=$!
( api REGISTER "" -H "X-Rxpip-Invite: $INV3" -H "X-Rxpip-User: racer2"; echo "$CODE" > "$WORK/ri2" ) &
RI2=$!
wait $RI1 $RI2
a=$(cat "$WORK/ri1"); b=$(cat "$WORK/ri2")
if { [ "$a" = 200 ] && [ "$b" != 200 ]; } || { [ "$b" = 200 ] && [ "$a" != 200 ]; }; then ok "one invite, two racers: exactly one wins ($a/$b)"; else bad "one invite, two racers: exactly one wins" "$a/$b"; fi

# ============================================================================
section "step 2: tokens"
api WHOAMI "$TOKC"
expect "WHOAMI names the user" "$BODY" "USER: carol"
api WHOAMI "rxp_00000000_000000000000000000000000000000000000000000000000"
expect "unknown token is refused" "$BODY" "BAD_TOKEN"
[ "$CODE" = 401 ] && ok "unknown token gives HTTP 401" || bad "unknown token gives HTTP 401" "got $CODE"
LASTC=${TOKC: -1}; FLIP=0; [ "$LASTC" = 0 ] && FLIP=1
api WHOAMI "${TOKC%?}$FLIP"
expect "token with one wrong character is refused" "$BODY" "BAD_TOKEN"
api WHOAMI "$TOKC" "$BASE?action=WHOAMI&token=$TOKC"
expect "token in URL is refused here too" "$(curl -s -X POST -H "X-Rxpip-Token: $TOKC" "$BASE?action=WHOAMI&token=$TOKC")" "TOKEN_IN_URL"
expect "GET is refused for authenticated actions" "$(get action=WHOAMI)" "METHOD_NOT_ALLOWED"
api NEWTOKEN "$TOKC" -H "X-Rxpip-Label: laptop"
TOKC2=$(printf '%s\n' "$BODY" | sed -n 's/^TOKEN: //p')
expect "NEWTOKEN returns a new token" "$TOKC2" "rxp_"
api TOKENS "$TOKC"
expect "TOKENS lists both tokens" "$BODY" "COUNT: 2"
expect "TOKENS shows the label" "$BODY" "LABEL: laptop"
expect_not "TOKENS never shows secrets" "$BODY" "${TOKC2##*_}"
ID2=$(printf '%s' "$TOKC2" | cut -d_ -f2)
api REVOKE "$TOKC" -H "X-Rxpip-Token-Id: $ID2"
expect "REVOKE removes a token" "$BODY" "revoked"
api WHOAMI "$TOKC2"
expect "a revoked token stops working" "$BODY" "BAD_TOKEN"
api WHOAMI "$TOKC"
expect "the other token still works" "$BODY" "USER: carol"
IDA=$(printf '%s' "$TOKA" | cut -d_ -f2)
api REVOKE "$TOKC" -H "X-Rxpip-Token-Id: $IDA"
expect "cannot revoke someone else's token" "$BODY" "NOT_FOUND"
api WHOAMI "$TOKA"
expect "alice's token survived that attempt" "$BODY" "USER: alice"

# ============================================================================
section "step 2: owners"
expect "OWNERS lists the claimant" "$(get 'action=OWNERS&name=mathutils')" "OWNERS: alice"
pub mathutils 2.0.0 "$TOKC" "$WORK/mathutils.rxpkg"
expect "a non-owner cannot publish" "$BODY" "FORBIDDEN"
[ "$CODE" = 403 ] && ok "non-owner gives HTTP 403" || bad "non-owner gives HTTP 403" "got $CODE"
api ADDOWNER "$TOKC" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: carol"
expect "a non-owner cannot add owners" "$BODY" "FORBIDDEN"
api ADDOWNER "$TOKA" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: nosuchuser"
expect "adding an unknown user is refused" "$BODY" "NO_SUCH_USER"
api ADDOWNER "$TOKA" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: carol"
expect "an owner can add an owner" "$BODY" "OWNERS: alice carol"
api ADDOWNER "$TOKA" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: carol"
expect "adding twice is harmless" "$BODY" "OWNERS: alice carol"
pub mathutils 2.0.0 "$TOKC" "$WORK/mathutils.rxpkg"
expect "the new owner can publish" "$BODY" "MESSAGE: published"
pub mathutils 2.0.1 "$TOKB" "$WORK/mathutils.rxpkg"
expect "bob is still locked out" "$BODY" "FORBIDDEN"
api REMOVEOWNER "$TOKC" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: alice"
expect "an owner can remove another owner" "$BODY" "OWNERS: carol"
api REMOVEOWNER "$TOKC" -H "X-Rxpip-Name: mathutils" -H "X-Rxpip-User: carol"
expect "the last owner cannot be removed" "$BODY" "LAST_OWNER"
pub mathutils 2.0.2 "$TOKA" "$WORK/mathutils.rxpkg"
expect "a removed owner can no longer publish" "$BODY" "FORBIDDEN"
api ADDOWNER "$TOKA" -H "X-Rxpip-Name: nonexistentpkg" -H "X-Rxpip-User: carol"
expect "owner changes on an unknown package are refused" "$BODY" "NOT_FOUND"
api ADDOWNER "$TOKC" -H "X-Rxpip-Name: ../x" -H "X-Rxpip-User: alice"
expect "unsafe package name is refused" "$BODY" "BAD_NAME"
expect "admin can restore ownership" "$(adm setowners mathutils alice carol)" "mathutils: alice carol"
adm lock carol > /dev/null
api WHOAMI "$TOKC"
expect "admin lock revokes all of a user's tokens" "$BODY" "BAD_TOKEN"

# ============================================================================
section "step 1: client publish / install / run (real client over HTTP)"
CH=$WORK/clienthome
export RXPIP_HOME=$CH
mkdir -p "$CH"
RX="regina -a $ROOT/client/rxpip.rexx"
$RX config set REPO_URL "$BASE" >/dev/null 2>&1
CTOK=$TOKA
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.0 --token=$CTOK --summary="client test" 2>&1)
expect "client publish succeeds" "$out" "STATUS: OK"
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.1 --token=short 2>&1)
expect "client rejects short token locally" "$out" "16-128"
out=$($RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.2 --token=$TOKB 2>&1)
expect "client shows server FORBIDDEN for wrong token" "$out" "FORBIDDEN"
out=$(RXPIP_TOKEN=$CTOK $RX publish "$WORK/greetutils.rxpkg" --name=cligreet --version=1.0.3 2>&1)
expect "client takes token from RXPIP_TOKEN" "$out" "STATUS: OK"
grep -rq "$CTOK" "$REPO" && bad "client token never stored in clear on server" || ok "client token never stored in clear on server"
out=$($RX install cligreet 2>&1)
expect "client install works" "$out" "cligreet"
ls /tmp 2>/dev/null | grep -q rxpip_hdr_ && bad "token header file removed" || ok "token header file removed"
unset RXPIP_HOME

# ============================================================================
section "client: version requirements (>=)"
export RXPIP_HOME=$WORK/clienthome3
mkdir -p "$RXPIP_HOME"
$RX config set REPO_URL "$BASE" >/dev/null 2>&1
export RXPIP_TOKEN=$TOKA
$RX publish "$WORK/mathutils.rxpkg" --name=vlib --version=1.0.0 >/dev/null 2>&1
$RX publish "$WORK/mathutils.rxpkg" --name=vlib --version=1.5.0 >/dev/null 2>&1
$RX publish "$WORK/strutils.rxpkg" --name=vapp --version=1.0.0 --requires="vlib>=1.0.0" >/dev/null 2>&1
unset RXPIP_TOKEN
out=$($RX install vapp 2>&1)
expect "installing vapp pulls its dependency" "$out" "installing vlib"
$RX list 2>&1 | grep -q '^vlib  *1\.5\.0' && ok ">=1.0.0 installs the LATEST version, not exactly 1.0.0" || bad ">=1.0.0 installs the LATEST version, not exactly 1.0.0" "$($RX list 2>&1)"
printf '/* REQUIRE vlib>=2.0.0 */\nsay 1\n' > "$WORK/needs2.rexx"
rm -rf "$RXPIP_HOME/pkgs" "$RXPIP_HOME/installed.txt" "$RXPIP_HOME/lib"/*
expect "an unmet minimum is reported" "$($RX scan "$WORK/needs2.rexx" 2>&1)" "needs version >=2.0.0"
printf '/* REQUIRE vlib>=1.2.0 */\nsay 1\n' > "$WORK/needs1.rexx"
expect "a satisfiable minimum installs" "$($RX scan "$WORK/needs1.rexx" 2>&1)" "installing vlib 1.5.0"
unset RXPIP_HOME

# ============================================================================
section "step 2: client accounts, tokens, owners"
export RXPIP_HOME=$WORK/clienthome2
mkdir -p "$RXPIP_HOME"
$RX config set REPO_URL "$BASE" >/dev/null 2>&1
CINV=$(adm invite client | sed 's/.*: //; s/ .*//' | head -1)
out=$($RX register --user=gina --invite=$CINV 2>&1)
expect "client register succeeds" "$out" "registered as gina"
expect_not "register does not echo the token" "$out" "rxp_"
perm=$(stat -c %a "$RXPIP_HOME/credentials.txt" 2>/dev/null || stat -f %Lp "$RXPIP_HOME/credentials.txt")
[ "$perm" = 600 ] && ok "credentials file is mode 600" || bad "credentials file is mode 600" "mode $perm"
expect "whoami uses the saved login" "$($RX whoami 2>&1)" "USER: gina"
out=$($RX publish "$WORK/strutils.rxpkg" --name=ginapkg --version=1.0.0 2>&1)
expect "publish works from the saved login (no --token)" "$out" "MESSAGE: published"
expect "owner list" "$($RX owner list ginapkg 2>&1)" "OWNERS: gina"
out=$($RX owner add ginapkg alice 2>&1)
expect "owner add" "$out" "OWNERS: gina alice"
out=$($RX owner remove ginapkg alice 2>&1)
expect "owner remove" "$out" "OWNERS: gina"
out=$($RX owner remove ginapkg gina 2>&1)
expect "client shows LAST_OWNER" "$out" "LAST_OWNER"
out=$($RX token new --label=ci 2>&1)
expect "token new prints a token once" "$out" "TOKEN: rxp_"
NEWT=$(printf '%s\n' "$out" | sed -n 's/^TOKEN: //p')
out=$($RX token list 2>&1)
expect "token list shows both" "$out" "COUNT: 2"
NID=$(printf '%s' "$NEWT" | cut -d_ -f2)
expect "token revoke" "$($RX token revoke $NID 2>&1)" "revoked"
expect "revoked token no longer logs in" "$(RXPIP_TOKEN=$NEWT $RX login 2>&1)" "BAD_TOKEN"
expect "login with a good token" "$(RXPIP_TOKEN=$TOKB $RX login 2>&1)" "logged in as bob"
expect "whoami now says bob" "$($RX whoami 2>&1)" "USER: bob"
$RX logout >/dev/null 2>&1
expect "whoami after logout" "$($RX whoami 2>&1)" "not logged in"
[ -e "$RXPIP_HOME/credentials.txt" ] && bad "logout removes the credentials file" || ok "logout removes the credentials file"
out=$($RX publish "$WORK/strutils.rxpkg" --name=ginapkg --version=1.0.1 2>&1)
expect "publish without login is refused locally" "$out" "login"
unset RXPIP_HOME

# ============================================================================
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" = 0 ]
