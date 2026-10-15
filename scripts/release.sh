#!/bin/bash
# Build a release of Lattice from a tag, on the maintainer's Mac: Developer ID signature, Apple
# notarisation, stapled ticket → build/Lattice-X.Y.Z.zip (+ .sha256) and a filled-in Homebrew cask.
# LATTICE_OUT=DIR builds somewhere else than build/ (e.g. while your daily Lattice runs from build/).
#
#   git tag -a v0.1.0 -m "Lattice 0.1.0" && git checkout v0.1.0
#   scripts/release.sh v0.1.0                    → build/Lattice-0.1.0.zip, build/lattice.rb
#   scripts/release.sh v0.1.0 --skip-notarize    → same, without notarising (a dry run of the pipeline)
#
# Needs (in scripts/signing.env, local only, or the environment):
#   LATTICE_SIGN_IDENTITY="Developer ID Application: …"
#   LATTICE_NOTARY_PROFILE="lattice"   # created once with `xcrun notarytool store-credentials lattice`
# Publishing (GitHub release, tap update) is separate and manual — see docs/releasing.md.
set -euo pipefail
cd "$(dirname "$0")/.."
red() { printf '\033[31m%s\033[0m\n' "$*"; }
die() { red "✗ $*"; exit 1; }

TAG="${1:-}"; SKIP_NOTARIZE=0
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1
[[ "$TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "usage: scripts/release.sh vX.Y.Z [--skip-notarize]"
VERSION="${BASH_REMATCH[1]}"

[[ -f scripts/signing.env ]] && source scripts/signing.env
IDENTITY="${LATTICE_SIGN_IDENTITY:-}"
[[ "$IDENTITY" == "Developer ID Application:"* ]] || die "LATTICE_SIGN_IDENTITY must be a 'Developer ID Application' identity"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  PROFILE="${LATTICE_NOTARY_PROFILE:-}"
  [[ -n "$PROFILE" ]] || die "set LATTICE_NOTARY_PROFILE (see docs/releasing.md)"
fi

# The release must be exactly the tagged, published commit.
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git cat-file -t "$TAG" 2>/dev/null)" == "tag" ]] || die "$TAG is not an annotated tag (git tag -a $TAG)"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$TAG^{commit}")" ]] || die "HEAD is not $TAG (git checkout $TAG)"
git merge-base --is-ancestor "$TAG" main || die "$TAG is not on main"
scripts/check-public.sh "$TAG" || die "leak check failed"
swift test || die "tests failed"

OUT="${LATTICE_OUT:-build}"; export LATTICE_OUT="$OUT"
APP="$OUT/Lattice.app"
ZIP="$OUT/Lattice-$VERSION.zip"
LATTICE_VERSION="$VERSION" LATTICE_TIMESTAMP=1 scripts/build-app.sh

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  echo "→ notarising (usually a few minutes)…"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait || die "notarisation failed (xcrun notarytool log <id> --keychain-profile $PROFILE)"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP" || die "Gatekeeper rejects the notarised app"
else
  red "⚠️  --skip-notarize: this build will be blocked by Gatekeeper on other Macs — don't publish it"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"      # ditto keeps the signature + stapled ticket intact
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/lattice.rb > "$OUT/lattice.rb"

echo
echo "✓ $ZIP  sha256 $SHA"
echo "  cask: $OUT/lattice.rb"
echo "Next (see docs/releasing.md):"
echo "  git push origin $TAG"
echo "  gh release create $TAG $ZIP $ZIP.sha256 --title \"Lattice $VERSION\" --generate-notes"
echo "  copy $OUT/lattice.rb to the tap's Casks/lattice.rb and push it"
