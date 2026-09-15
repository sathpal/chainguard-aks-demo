#!/usr/bin/env bash
# Scans both images with grype (and trivy if present); writes JSON + tables to out/.
. "$(dirname "$0")/common.sh"
need grype
for f in "${FLAVORS[@]}"; do
  bold ">> grype $APP:$f"
  grype "$APP:$f" -o json --file "$OUT/$f.grype.json" -q
  grype "$APP:$f" -o table -q > "$OUT/$f.grype.txt" || true
  head -25 "$OUT/$f.grype.txt"; echo "   ... full table: $OUT/$f.grype.txt"
  if command -v trivy >/dev/null; then
    trivy image -q --scanners vuln -f json -o "$OUT/$f.trivy.json" "$APP:$f"
  fi
done
"$ROOT/scripts/compare.sh"
