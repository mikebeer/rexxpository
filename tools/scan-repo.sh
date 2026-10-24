#!/bin/sh
# Scan everything stored in the repository with ClamAV and report hits.
# Meant for cron (weekly), run as root on the server:
#   0 4 * * 0  /opt/rexxpository/tools/scan-repo.sh
# Uploads are already scanned when they arrive (RXPIP_SCANNER); this catches
# files that only became detectable after new virus signatures were loaded.
#
#   REPO         repository directory (default /var/www/rexxpository/repo)
#   MAILTO       where to send a report when something is found (needs mail)
#   SCAN_CMD     scanner (default: clamscan)
REPO=${REPO:-/var/www/rexxpository/repo}
SCAN_CMD=${SCAN_CMD:-clamscan}
OUT=$(mktemp) || exit 2
# .auth and .staging hold no packages; skip them
$SCAN_CMD -r --infected --no-summary --exclude-dir='^'"$REPO"'/\.auth' --exclude-dir='^'"$REPO"'/\.staging' "$REPO" > "$OUT" 2>&1
rc=$?
case $rc in
  0) rm -f "$OUT"; exit 0 ;;
  1) echo "rxpip: the virus scan found infected files in $REPO:"; cat "$OUT"
     [ -n "$MAILTO" ] && mail -s "rexxpository: virus scan found infected files" "$MAILTO" < "$OUT"
     rm -f "$OUT"; exit 1 ;;
  *) echo "rxpip: the virus scan could not run (exit $rc):"; cat "$OUT"
     [ -n "$MAILTO" ] && mail -s "rexxpository: virus scan did not run" "$MAILTO" < "$OUT"
     rm -f "$OUT"; exit 2 ;;
esac
