#!/usr/bin/env bash
# Prints the headline comparison table from out/*.grype.json and docker inspect.
. "$(dirname "$0")/common.sh"
need jq
printf '\n%-12s %8s %6s %6s %6s %6s %6s  %-10s %-6s %-6s\n' IMAGE SIZE TOTAL CRIT HIGH MED LOW USER SHELL PKGMGR
for f in "${FLAVORS[@]}"; do
  j="$OUT/$f.grype.json"; [ -f "$j" ] || { echo "run scripts/scan.sh first"; exit 1; }
  cnt() { jq "[.matches[] | select(.vulnerability.severity==\"$1\")] | length" "$j"; }
  total=$(jq '.matches | length' "$j")
  size=$(docker images "$APP:$f" --format '{{.Size}}')
  user=$(docker image inspect "$APP:$f" --format '{{.Config.User}}'); user=${user:-root}
  shell=$(docker run --rm --entrypoint python "$APP:$f" -c 'import os;print("yes" if os.path.exists("/bin/sh") else "no")' 2>/dev/null || echo "?")
  pm=$(docker run --rm --entrypoint python "$APP:$f" -c 'import os;print("yes" if any(map(os.path.exists,["/usr/bin/apt","/sbin/apk","/usr/bin/pip"])) else "no")' 2>/dev/null || echo "?")
  printf '%-12s %8s %6s %6s %6s %6s %6s  %-10s %-6s %-6s\n' "$f" "$size" "$total" "$(cnt Critical)" "$(cnt High)" "$(cnt Medium)" "$(cnt Low)" "$user" "$shell" "$pm"
done
echo
