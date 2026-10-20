#!/bin/sh
# Publish the current client sources as releases on the repository, one per
# kind (regina, oorexx, netrexx, crexx), reading each version from the
# source's own ClientVersion. Run from a checkout, logged in as an
# administrator:   tools/publish-clients.sh [--min=1.0.0] [kind...]
# RXPIP: command to run the client (default: regina -a client/rxpip.rexx)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RXPIP=${RXPIP:-regina -a $ROOT/client/rxpip.rexx}
MIN=
case "$1" in --min=*) MIN=$1; shift;; esac
KINDS=${*:-regina oorexx netrexx crexx}
version_of() {   # version_of <source file>  -> the number ClientVersion returns
  awk 'tolower($0) ~ /^ *(method )?clientversion(:| static| *$)/ {f=1; next} f && /return \047/ {gsub(/.*return \047|\047.*/, ""); print; exit}' "$1"
}
rc=0
for k in $KINDS; do
  S=$(mktemp -d) || exit 1
  case $k in
    regina)  src=$ROOT/client/rxpip.rexx;          cp "$ROOT/client/rxpip.rexx" "$ROOT/client/rxpip.bat" "$S/" ;;
    oorexx)  src=$ROOT/client/rxpip.rexx;          cp "$ROOT/client/rxpip.rexx" "$ROOT/client/oorexx/rxpip-oorexx" "$ROOT/client/oorexx/rxpip-oorexx.bat" "$S/" ;;
    netrexx) src=$ROOT/client/netrexx/Rxpip.nrx;   cp "$ROOT"/client/netrexx/Rxpip.nrx "$ROOT"/client/netrexx/rxpip-netrexx "$ROOT"/client/netrexx/rxpip-netrexx.bat "$S/" ;;
    crexx)   src=$ROOT/client/crexx/rxpip.crexx;   cp "$ROOT"/client/crexx/rxpip.crexx "$ROOT"/client/crexx/rxpip-crexx "$ROOT"/client/crexx/rxpip-crexx.bat "$S/" ;;
    *) echo "unknown kind $k"; rc=1; continue ;;
  esac
  v=$(version_of "$src")
  [ -n "$v" ] || { echo "$k: cannot read the version from $src"; rc=1; rm -rf "$S"; continue; }
  echo "== $k $v"
  $RXPIP admin client-publish "$k" --version="$v" $MIN "$S"/* || rc=1
  rm -rf "$S"
done
exit $rc
