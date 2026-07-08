#!/usr/bin/env bash
#
# publishGlossary.sh — sign the process glossary and publish it to the server.
#
# The glossary (Resources/glossary.json) is the "what is this process?" data clients
# download. This signs it with the LOCAL Ed25519 private key (catalog-signing.pem —
# the same key as the check catalog, kept off the server) and uploads the JSON plus
# its detached signature. Clients verify it with the public key embedded in the app,
# so a compromised server can't forge descriptions, and they match it on-device — no
# process name ever leaves the Mac.
#
# To ship new descriptions: edit Resources/glossary.json (add entries AND bump
# "version" above the bundled version), then run this. The /process-glossary skill
# can generate entries for processes your Macs have actually seen.
#
# Usage: Scripts/publishGlossary.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="secrets/catalog-signing.pem"
SRC="Resources/glossary.json"
DIR="glossary"
OUT="$DIR/glossary.json"
SIG="$DIR/glossary.json.sig"

[ -f "$KEY" ] || { echo "error: $KEY not found (private signing key)." >&2; exit 1; }
[ -f "$SRC" ] || { echo "error: $SRC not found." >&2; exit 1; }
python3 -c "import json; json.load(open('$SRC'))" \
  || { echo "error: $SRC is not valid JSON." >&2; exit 1; }

mkdir -p "$DIR"
cp "$SRC" "$OUT"
VERSION=$(/usr/bin/grep -o '"version"[[:space:]]*:[[:space:]]*[0-9]*' "$OUT" | head -1 | grep -o '[0-9]*')
echo "==> Glossary version: ${VERSION:-?}, $(/usr/bin/grep -c '"title"' "$OUT") entries"

echo "==> Signing"
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$OUT" -out "$DIR/.sig.bin"
base64 < "$DIR/.sig.bin" > "$SIG"
rm -f "$DIR/.sig.bin"

# Verify with the SAME check the client runs (CryptoKit Ed25519).
PUB=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
if swift run macperfmonitor-cli verify-checks "$OUT" "$SIG" "$PUB" >/dev/null 2>&1; then
  echo "    verified with the client's CryptoKit check ✓"
else
  echo "error: signature failed the client-side (CryptoKit) check — not publishing." >&2
  rm -f "$SIG"
  exit 1
fi

# Publish: the signed glossary + signature are tracked in the repo and served to
# clients from raw.githubusercontent.com/<owner>/<repo>/main/glossary/. Commit + push.
echo "==> Committing $OUT + $SIG"
git add "$OUT" "$SIG"
if git diff --cached --quiet -- "$OUT" "$SIG"; then
  echo "No glossary changes to publish."
else
  git commit -m "glossary: publish v${VERSION:-?}"
  git push
  echo "Published glossary (version ${VERSION:-?}). Clients pick it up on next launch."
fi
