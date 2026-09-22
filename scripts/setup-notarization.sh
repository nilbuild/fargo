#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<EOF
Store Apple notarization credentials in the macOS keychain.

Usage: scripts/setup-notarization.sh [OPTIONS]

Options:
  --apple-id EMAIL   Apple ID to store (otherwise you are asked)
  --team-id ID       Apple team id (default: ${DEVELOPMENT_TEAM})
  --profile NAME     Keychain profile name (default: ${NOTARY_KEYCHAIN_PROFILE})
  --help             Show this help

You need an app-specific password for the Apple ID, created at
https://appleid.apple.com -> Sign-In and Security -> App-Specific Passwords.
notarytool asks for it and never echoes it.

CI does not use this: there, set APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID
as repository secrets instead.
EOF
}

APPLE_ID_ARG="${APPLE_ID:-}"
TEAM_ID_ARG="$DEVELOPMENT_TEAM"
PROFILE="$NOTARY_KEYCHAIN_PROFILE"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apple-id) APPLE_ID_ARG="${2:-}"; shift 2 ;;
        --apple-id=*) APPLE_ID_ARG="${1#*=}"; shift ;;
        --team-id) TEAM_ID_ARG="${2:-}"; shift 2 ;;
        --team-id=*) TEAM_ID_ARG="${1#*=}"; shift ;;
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

require_cmd xcrun

if ! is_interactive; then
    die "this script is interactive; run it in a terminal.
       In CI, set APPLE_ID, APPLE_APP_PASSWORD and APPLE_TEAM_ID instead."
fi

step "Notarization credentials"
info "Profile:  ${PROFILE}"
info "Team ID:  ${TEAM_ID_ARG}"

if [[ -z "$APPLE_ID_ARG" ]]; then
    read -r -p "    Apple ID (email): " APPLE_ID_ARG
fi
[[ -n "$APPLE_ID_ARG" ]] || die "an Apple ID is required"

step "Storing credentials (notarytool will ask for the app-specific password)"
xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID_ARG" \
    --team-id "$TEAM_ID_ARG"

step "Verifying"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    info "Profile '${PROFILE}' works."
    info "You can now run: make release"
else
    die "stored the profile but could not reach the notary service with it - check the credentials and try again"
fi
