#!/usr/bin/env bash
#
# publishChecks.sh — sign the diagnostic check catalog and publish it to the server.
#
# The catalog (checks/manifest.json) is the declarative rule set clients download to
# run the deep-dive diagnostics. This signs it with the LOCAL Ed25519 private key
# (catalog-signing.pem — kept off the server, gitignored) and uploads the manifest
# plus its detached signature. Clients verify the signature with the public key
# embedded in the app, so a compromised server or CDN cannot forge or alter rules.
#
# Usage:
#   Scripts/publishChecks.sh --seed     # (re)create checks/manifest.json from the
#                                        # in-app built-in pack, then sign + upload
#   Scripts/publishChecks.sh            # sign + upload the current checks/manifest.json
#
# To ship a change: edit checks/manifest.json (add/tune rules AND bump "version"
# above the app's built-in version, currently 1), then run this. Clients adopt a
# downloaded manifest only when its signature is valid AND its version is newer.
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="secrets/catalog-signing.pem"
DIR="checks"
MANIFEST="$DIR/manifest.json"
SIG="$DIR/manifest.json.sig"

if [[ ! -f "$KEY" ]]; then
  echo "error: $KEY not found (the private signing key)." >&2
  echo "  Generate it once:  mkdir -p secrets && openssl genpkey -algorithm ed25519 -out $KEY && chmod 600 $KEY" >&2
  echo "  Then embed the public key in CheckCatalogStore:" >&2
  echo "    openssl pkey -in $KEY -pubout -outform DER | tail -c 32 | base64" >&2
  exit 1
fi

mkdir -p "$DIR"

if [[ "${1:-}" == "--seed" || ! -f "$MANIFEST" ]]; then
  echo "==> Seeding $MANIFEST from the built-in catalog"
  swift run macperfmonitor-cli emit-checks > "$MANIFEST"
  echo "    edit $MANIFEST to add/tune rules and bump \"version\" before publishing."
fi

VERSION=$(/usr/bin/grep -o '"version"[[:space:]]*:[[:space:]]*[0-9]*' "$MANIFEST" | head -1 | grep -o '[0-9]*')
echo "==> Catalog version: ${VERSION:-?}, $(/usr/bin/grep -c '"id"' "$MANIFEST") checks"

# Sign the EXACT manifest bytes (Ed25519, raw message — no pre-hash), base64 it.
echo "==> Signing"
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$MANIFEST" -out "$DIR/.sig.bin"
base64 < "$DIR/.sig.bin" > "$SIG"
rm -f "$DIR/.sig.bin"

# Verify with the SAME check the client runs (CryptoKit Ed25519), so we never ship a
# manifest clients would reject.
PUB=$(openssl pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64)
if swift run macperfmonitor-cli verify-checks "$MANIFEST" "$SIG" "$PUB" >/dev/null 2>&1; then
  echo "    verified with the client's CryptoKit check ✓"
else
  echo "error: signature failed the client-side (CryptoKit) check — not publishing." >&2
  rm -f "$SIG"
  exit 1
fi

# Publish: the signed manifest + signature are tracked in the repo and served to
# clients from raw.githubusercontent.com/<owner>/<repo>/main/checks/. Commit + push so
# clients see the new version on their next launch / next deep dive.
echo "==> Committing $MANIFEST + $SIG"
git add "$MANIFEST" "$SIG"
if git diff --cached --quiet -- "$MANIFEST" "$SIG"; then
  echo "No catalog changes to publish."
else
  git commit -m "checks: publish catalog v${VERSION:-?}"
  git push
  echo "Published checks catalog (version ${VERSION:-?})."
  echo "Clients pick it up on next launch / next deep dive if version > their current."
fi
