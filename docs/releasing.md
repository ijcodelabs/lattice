# Releasing Lattice

Releases are built, signed and notarised **locally on the maintainer's Mac** from an annotated
`vX.Y.Z` tag on `main`, then published to GitHub Releases and the Homebrew tap. Users download a
notarised app — they need no Xcode and no Apple developer account.

## Versions

- Semver tags on `main`: `v0.1.0`, `v0.2.0`, … — `v1.0.0` once the config format and commands are stable.
- The tag is the only source of the version: `scripts/build-app.sh` writes it into the app
  (`CFBundleShortVersionString` = tag without `v`, `CFBundleVersion` = `git describe`).
  `lattice version` prints both.
- Builds between tags show e.g. `0.1.0 (v0.1.0-5-g1a2b3c4)`.

## One-time setup

1. A **Developer ID Application** certificate in your login keychain
   (`security find-identity -v -p codesigning`).
2. A notarisation profile named `lattice` in the keychain — either way works:
   - **App Store Connect API key (recommended):** App Store Connect → Users and Access →
     Integrations → App Store Connect API → Team Keys → generate a key (access: Developer). Note the
     **Issuer ID** (UUID above the list) and **Key ID**, download `AuthKey_<KeyID>.p8` once, keep it
     outside the repo (e.g. `~/.private_keys/`), then:
     ```bash
     xcrun notarytool store-credentials lattice --key ~/.private_keys/AuthKey_<KeyID>.p8 \
       --key-id <KeyID> --issuer <Issuer ID>
     ```
   - **Apple ID:** `--apple-id` is your Apple ID **email address** and the password is an
     **app-specific password** (`xxxx-xxxx-xxxx-xxxx`, from account.apple.com → Sign-In and
     Security → App-Specific Passwords) — your normal password is rejected with HTTP 401:
     ```bash
     xcrun notarytool store-credentials lattice --apple-id <email> --team-id <team ID>
     ```
3. `scripts/signing.env` (git-ignored, never committed):
   ```bash
   LATTICE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
   LATTICE_NOTARY_PROFILE="lattice"
   ```

## Making a release

```bash
git switch main && git pull
git tag -a v0.1.0 -m "Lattice 0.1.0"
git checkout v0.1.0
scripts/release.sh v0.1.0          # tests, leak check, build, sign, notarise, staple, zip
git switch main
git push origin v0.1.0             # one tag at a time — never `git push --tags`
gh release create v0.1.0 build/Lattice-0.1.0.zip build/Lattice-0.1.0.zip.sha256 \
  --title "Lattice 0.1.0" --generate-notes
```

`scripts/release.sh` refuses to run unless the tree is clean, `HEAD` is exactly the annotated tag, the
tag is on `main`, the leak check passes and `swift test` passes. It ends with
`spctl --assess` (Gatekeeper must accept the app) and writes:

- `build/Lattice-X.Y.Z.zip` and `.zip.sha256` — the release assets
- `build/lattice.rb` — the Homebrew cask, filled in from `packaging/homebrew/lattice.rb`

`scripts/release.sh vX.Y.Z --skip-notarize` runs the whole pipeline without notarising (a dry run —
never publish its output). `LATTICE_OUT=DIR` builds into another folder than `build/`, e.g. while
your everyday Lattice runs from `build/Lattice.app`.

## Homebrew

The cask lives in the tap repository `ijcodelabs/homebrew-tap` as `Casks/lattice.rb`. After the
GitHub release is up, copy `build/lattice.rb` there, commit and push. Users install with:

```bash
brew install --cask ijcodelabs/tap/lattice
```

The cask installs `Lattice.app` and links the `lattice` command; `brew uninstall --zap` also removes
the config, saved layout and logs.
