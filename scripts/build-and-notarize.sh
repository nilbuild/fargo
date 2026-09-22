#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ARCH="universal"
VERSION_ARG=""
BUMP_TYPE=""
BUMP_ONLY=false
SKIP_NOTARIZE=false
SKIP_RESIGN=false
OUTPUT_DIR=""

usage() {
    cat <<EOF
${APP_NAME} build, sign, notarize and package.

Usage: scripts/build-and-notarize.sh [OPTIONS]

Options:
  --arch {arm64|x86_64|universal}  Target architecture (default: universal)
  --version X.Y.Z                  Set MARKETING_VERSION to this value and build it
  --bump {major|minor|patch}       Bump the version before building
  --bump-only                      Only bump the version, do not build
  --skip-notarize                  Build and package without notarizing
  --skip-resign                    Keep Xcode's export signature, skip the re-sign pass
  --output-dir DIR                 Where artifacts are written (default: build/<arch>)
  --help                           Show this help

Outputs (in the output directory):
  ${APP_NAME}-<version>-<arch>.zip  Notarized + stapled app archive (Sparkle payload)
  ${APP_NAME}-<version>-<arch>.dmg  Notarized + stapled disk image (manual download)
  export/${APP_NAME}.app            The exported application bundle
  build.log                     Full xcodebuild output

Environment:
  DEVELOPMENT_TEAM          Apple team id (default: ${DEVELOPMENT_TEAM})
  SIGNING_IDENTITY          Codesign identity (default: auto-detected "Developer ID Application")
  NOTARY_KEYCHAIN_PROFILE   notarytool keychain profile (default: ${NOTARY_KEYCHAIN_PROFILE})
  APPLE_ID                  Apple ID for notarization (CI: set with the two below)
  APPLE_APP_PASSWORD        App-specific password for that Apple ID
  APPLE_TEAM_ID             Team id for notarization
                            When all three are set they are used instead of the
                            keychain profile, so CI never needs a keychain.

Examples:
  scripts/build-and-notarize.sh
  scripts/build-and-notarize.sh --arch arm64 --skip-notarize
  scripts/build-and-notarize.sh --bump patch
  scripts/build-and-notarize.sh --version 1.2.0 --output-dir dist

Notes:
  * Without a Developer ID certificate the script can only run with
    --skip-notarize, and produces an ad-hoc signed build for local testing.
  * The appcast is not touched here; run scripts/generate-appcast.sh afterwards.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:-}"; shift 2 ;;
        --arch=*) ARCH="${1#*=}"; shift ;;
        --version) VERSION_ARG="${2:-}"; shift 2 ;;
        --version=*) VERSION_ARG="${1#*=}"; shift ;;
        --bump) BUMP_TYPE="${2:-}"; shift 2 ;;
        --bump=*) BUMP_TYPE="${1#*=}"; shift ;;
        --bump-only) BUMP_ONLY=true; shift ;;
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        --skip-resign) SKIP_RESIGN=true; shift ;;
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

case "$ARCH" in
    arm64) ARCHS="arm64" ;;
    x86_64) ARCHS="x86_64" ;;
    universal) ARCHS="arm64 x86_64" ;;
    *) die "invalid architecture '${ARCH}' (use arm64, x86_64 or universal)" ;;
esac

if [[ -n "$BUMP_TYPE" && -n "$VERSION_ARG" ]]; then
    die "--version and --bump are mutually exclusive"
fi

require_cmd xcodebuild
require_cmd xcrun
require_cmd ditto
[[ -f "$PBXPROJ" ]] || die "Xcode project not found at ${XCODE_PROJECT}"

if [[ -n "$BUMP_TYPE" ]]; then
    step "Bumping version (${BUMP_TYPE})"
    bump_version "$BUMP_TYPE"
elif [[ -n "$VERSION_ARG" ]]; then
    validate_version "$VERSION_ARG"
    if [[ "$VERSION_ARG" != "$(get_version)" ]]; then
        step "Setting version to ${VERSION_ARG}"
        info "Version: $(get_version) -> ${VERSION_ARG}"
        set_version "$VERSION_ARG"
        set_build_number "$(( $(get_build_number) + 1 ))"
        info "Build number: $(get_build_number)"
    fi
fi

VERSION="$(get_version)"
BUILD_NUMBER="$(get_build_number)"

if [[ "$BUMP_ONLY" == true ]]; then
    step "Version bumped, skipping build"
    info "${VERSION} (build ${BUILD_NUMBER})"
    exit 0
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${REPO_ROOT}/build/${ARCH}"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

ARCHIVE_PATH="${OUTPUT_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${OUTPUT_DIR}/export"
APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
DMG_STAGING="${OUTPUT_DIR}/dmg-staging"
ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-${ARCH}.zip"
DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-${ARCH}.dmg"
BUILD_LOG="${OUTPUT_DIR}/build.log"
EXPORT_OPTIONS="${OUTPUT_DIR}/ExportOptions.plist"

detect_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)"$/\1/p' \
        | head -1
}

IDENTITY="${SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(detect_signing_identity || true)"
fi

SIGNED=true
if [[ -z "$IDENTITY" ]]; then
    SIGNED=false
    if [[ "$SKIP_NOTARIZE" != true ]]; then
        die "no 'Developer ID Application' identity found in the keychain.
       Install your Developer ID certificate, set SIGNING_IDENTITY, or pass --skip-notarize."
    fi
    warn "no Developer ID identity found - building an ad-hoc signed app (not distributable)"
fi

NOTARY_ARGS=()
if [[ "$SKIP_NOTARIZE" != true ]]; then
    if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
        NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
    else
        if [[ -n "${APPLE_ID:-}${APPLE_APP_PASSWORD:-}${APPLE_TEAM_ID:-}" ]]; then
            die "APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID must all be set together"
        fi
        NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        if ! is_interactive && ! xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
            die "keychain profile '${NOTARY_KEYCHAIN_PROFILE}' is not available and no APPLE_ID/APPLE_APP_PASSWORD/APPLE_TEAM_ID were provided.
       Run scripts/setup-notarization.sh locally, or set those variables in CI."
        fi
    fi
fi

# notarytool's exit code is not reliable, so the status is read from its JSON.
notarize() {
    local file="$1" result submission_id status
    result="$(xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" --wait --output-format json 2>&1)" || true
    submission_id="$(printf '%s' "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
    status="$(printf '%s' "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"

    info "Submission ${submission_id:-unknown}: ${status:-no status}"

    if [[ "$status" != "Accepted" ]]; then
        printf '%s\n' "$result" >&2
        if [[ -n "$submission_id" ]]; then
            warn "notary log for ${submission_id}:"
            xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" >&2 || true
        fi
        die "notarization failed for $(basename "$file")"
    fi
}

step "Building ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER})"
info "Architecture:  ${ARCH} (${ARCHS})"
info "Signing:       $([[ "$SIGNED" == true ]] && printf '%s' "$IDENTITY" || printf 'ad-hoc (unsigned)')"
info "Notarization:  $([[ "$SKIP_NOTARIZE" == true ]] && printf 'skipped' || printf 'enabled')"
info "Output:        ${OUTPUT_DIR}"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_STAGING" "$ZIP_PATH" "$DMG_PATH"
: > "$BUILD_LOG"

XCODEBUILD_ARGS=(
    -project "$XCODE_PROJECT"
    -scheme "$SCHEME"
    -configuration Release
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    ARCHS="$ARCHS"
    ONLY_ACTIVE_ARCH=NO
)

if [[ "$SIGNED" == true ]]; then
    XCODEBUILD_ARGS+=(
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$IDENTITY"
        PROVISIONING_PROFILE_SPECIFIER=""
        OTHER_CODE_SIGN_FLAGS="--timestamp"
    )
else
    XCODEBUILD_ARGS+=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        CODE_SIGN_IDENTITY=""
        CODE_SIGN_ENTITLEMENTS=""
    )
fi

step "Archiving"
if ! xcodebuild archive "${XCODEBUILD_ARGS[@]}" >>"$BUILD_LOG" 2>&1; then
    tail -40 "$BUILD_LOG" >&2
    die "xcodebuild archive failed - full log at ${BUILD_LOG}"
fi
info "Archive: ${ARCHIVE_PATH}"

if [[ "$SIGNED" == true ]]; then
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${IDENTITY}</string>
</dict>
</plist>
EOF

    step "Exporting archive"
    if ! xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" >>"$BUILD_LOG" 2>&1; then
        tail -40 "$BUILD_LOG" >&2
        die "xcodebuild -exportArchive failed - full log at ${BUILD_LOG}"
    fi
else
    step "Extracting app from archive (unsigned build)"
    mkdir -p "$EXPORT_PATH"
    cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "$EXPORT_PATH/"
    codesign --force --deep --sign - "$APP_PATH" 2>>"$BUILD_LOG"
fi

[[ -d "$APP_PATH" ]] || die "application not found at ${APP_PATH}"
info "App: ${APP_PATH}"

if [[ "$SIGNED" == true && "$SKIP_RESIGN" != true ]]; then
    # Xcode only re-signs the outer Sparkle.framework; the nested Autoupdate,
    # Updater.app and XPC services keep an ad-hoc signature notarization rejects.
    step "Re-signing bundle"
    resign_app "$APP_PATH" "$IDENTITY" "$ENTITLEMENTS"
fi

step "Verifying signature"
if [[ "$SIGNED" == true ]]; then
    codesign --verify --deep --strict --verbose=1 "$APP_PATH"
    assert_no_adhoc_signatures "$APP_PATH"
    info "Signature valid, nothing left ad-hoc signed"
else
    codesign --verify --deep "$APP_PATH"
    info "Ad-hoc signature valid"
fi

info "Architectures: $(lipo -info "${APP_PATH}/Contents/MacOS/${APP_NAME}" | sed 's/.*: //')"

make_zip() {
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
}

step "Creating ZIP"
make_zip
info "$(basename "$ZIP_PATH") ($(file_size "$ZIP_PATH") bytes)"

if [[ "$SKIP_NOTARIZE" != true ]]; then
    step "Notarizing app"
    notarize "$ZIP_PATH"

    step "Stapling ticket to the app"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"

    # The submitted ZIP holds the un-stapled app, so rebuild it after stapling.
    step "Repackaging stapled app"
    make_zip
    info "$(basename "$ZIP_PATH") ($(file_size "$ZIP_PATH") bytes)"
fi

step "Creating DMG"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "${DMG_STAGING}/Applications"

if command -v create-dmg >/dev/null 2>&1; then
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 150 190 \
        --hide-extension "${APP_NAME}.app" \
        --icon "Applications" 450 190 \
        "$DMG_PATH" \
        "$DMG_STAGING" >>"$BUILD_LOG" 2>&1 \
        || die "create-dmg failed - full log at ${BUILD_LOG}"
else
    detail "create-dmg not installed, falling back to hdiutil"
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
        -ov -format UDZO "$DMG_PATH" >>"$BUILD_LOG" 2>&1 \
        || die "hdiutil create failed - full log at ${BUILD_LOG}"
fi
rm -rf "$DMG_STAGING"
info "$(basename "$DMG_PATH") ($(file_size "$DMG_PATH") bytes)"

if [[ "$SKIP_NOTARIZE" != true ]]; then
    step "Notarizing DMG"
    notarize "$DMG_PATH"

    step "Stapling ticket to the DMG"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

step "Done"
info "Version:      ${VERSION} (build ${BUILD_NUMBER})"
info "Architecture: ${ARCH}"
info "App:          ${APP_PATH}"
info "ZIP:          ${ZIP_PATH}"
info "DMG:          ${DMG_PATH}"
info "Log:          ${BUILD_LOG}"

if [[ "$SKIP_NOTARIZE" == true ]]; then
    warn "this build was not notarized - do not ship it"
else
    printf '\n'
    info "Next: scripts/generate-appcast.sh --version ${VERSION} --build ${BUILD_NUMBER} --zip \"${ZIP_PATH}\""
fi
