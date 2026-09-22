# Fargo Release Runbook

How to build a signed, notarized release of Fargo and ship it through Sparkle.

## One-time setup

### 1. Notarization credentials

```bash
make setup
```

This runs `scripts/setup-notarization.sh`. It asks for your Apple ID and an
app-specific password, then stores them in the keychain as a `notarytool`
profile. Make the app-specific password at
[appleid.apple.com](https://appleid.apple.com). Do not use your normal
password. You also need your Apple Team ID.

### 2. Sparkle keys

```bash
make setup-sparkle
```

This runs `scripts/setup-sparkle-keys.sh`. It makes an EdDSA key pair that
signs the Sparkle update feed. The private key is used on your Mac, and in CI,
to sign release archives. The public key goes into `Info.plist` under
`SUPublicEDKey`. Never commit the private key. `.sparkle/` is gitignored.

### 3. GitHub secrets (for releases from CI)

`.github/workflows/release.yml` needs these repository secrets:

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate (base64 `.p12`) |
| `P12_PASSWORD` | Password for the `.p12` above |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key from step 2, for signing the appcast |

### 4. gh-pages / appcast

The appcast is served from the `gh-pages` branch at
`https://nilbuild.github.io/fargo/appcast.xml`. `SUFeedURL` in `Info.plist`
already points there, so there is nothing to set up for each release. You only
have to turn on GitHub Pages for that branch once (Settings → Pages → source:
`gh-pages`).

## Making a release

### Local (unsigned dev build)

```bash
make build     # build
make run       # build + launch
make test      # run FargoTests
```

### Local (signed + notarized)

```bash
make release          # build, sign, notarize the current version
make patch             # bump patch version and release (1.0.0 -> 1.0.1)
make minor             # bump minor version and release
make major             # bump major version and release
make bump-patch         # bump version only, no build
make bump-minor
make bump-major
make appcast            # regenerate appcast.xml from release artifacts
```

`make version` prints the current version from the Xcode project.

### CI (the recommended way)

1. Bump the version (`make bump-patch` / `bump-minor` / `bump-major`) and commit.
2. Tag it: `git tag v<version> && git push origin v<version>`.
3. `.github/workflows/release.yml` sees the `v*` tag and does this:
   - Builds a universal binary
   - Signs it with the Developer ID certificate
   - Notarizes it and staples the ticket
   - Makes `Fargo-<version>-universal.dmg` and `.zip`
   - Signs the update archive with the Sparkle private key
   - Publishes to GitHub Releases
   - Updates `appcast.xml` on `gh-pages`

`.github/workflows/ci.yml` runs on every PR. It does an unsigned build and
`make test`. It is separate from the release pipeline.

## How the pieces fit together

```
git tag v1.2.3
      │
      ▼
release.yml (GitHub Actions)
      │
      ├─ scripts/build-and-notarize.sh   → signed, notarized .app/.dmg/.zip
      ├─ scripts/sign-update.sh          → EdDSA signature over the .zip
      ├─ scripts/generate-appcast.sh     → appcast.xml entry
      │
      ▼
GitHub Release (v1.2.3)          gh-pages branch
  Fargo-1.2.3-universal.dmg  ←    appcast.xml (points here)
  Fargo-1.2.3-universal.zip
      │
      ▼
Existing installs poll SUFeedURL → Sparkle downloads .zip → verifies EdDSA
signature against SUPublicEDKey → installs update
```

## Troubleshooting

**Notarization fails**
- Check the credentials profile: `xcrun notarytool history --keychain-profile notarytool-profile`
- Check that the Developer ID Application certificate has not expired
- Look for hardened runtime or entitlement problems in the build log that the script prints

**Code signing problems**
- Run `security find-identity -v -p codesigning` to check that the Developer ID identity is there and trusted
- In CI, check that `BUILD_CERTIFICATE_BASE64` decodes to a valid `.p12` with `P12_PASSWORD`

**Appcast does not update**
- Check that `SPARKLE_PRIVATE_KEY` (CI) or `.sparkle/eddsa_private_key` (local) is there
- Check that GitHub Pages is serving the `gh-pages` branch
- Run `make appcast` again on your Mac and diff it against the published file

**The app does not update for users**
- Check that `SUPublicEDKey` in the shipped app's `Info.plist` matches the key used to sign the release you just made. If the keys do not match, signature verification fails quietly and Sparkle simply does not offer the update.
