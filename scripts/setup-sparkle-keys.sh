#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<EOF
Generate the Sparkle EdDSA key pair for signing ${APP_NAME} updates.

Usage: scripts/setup-sparkle-keys.sh [OPTIONS]

Options:
  --account NAME   Keychain account to hold the key (default: ${SPARKLE_KEY_ACCOUNT})
  --print          Only print the existing public key, generate nothing
  --help           Show this help

What it does:
  1. Downloads Sparkle's release tools into .sparkle/tools if they are missing
  2. Generates (or reuses) the EdDSA key pair in your login keychain
  3. Exports the private key to ${SPARKLE_PRIVATE_KEY_FILE#"${REPO_ROOT}/"}
  4. Writes the public key to ${SPARKLE_PUBLIC_KEY_FILE#"${REPO_ROOT}/"}

The public key goes into macos/${APP_NAME}/Info.plist under SUPublicEDKey.
The private key must never be committed; .sparkle/ is gitignored.
For CI, paste the private key file's contents into the SPARKLE_PRIVATE_KEY secret.
EOF
}

PRINT_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account) SPARKLE_KEY_ACCOUNT="${2:-}"; shift 2 ;;
        --account=*) SPARKLE_KEY_ACCOUNT="${1#*=}"; shift ;;
        --print) PRINT_ONLY=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

step "Checking that .sparkle/ is ignored by git"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$REPO_ROOT" check-ignore -q ".sparkle/eddsa_private_key"; then
        die ".sparkle/ is not ignored by git - add '.sparkle/' to .gitignore before generating keys"
    fi
    info "git ignores .sparkle/ - safe to continue"
elif ! grep -q '^\.sparkle/\?$' "${REPO_ROOT}/.gitignore" 2>/dev/null; then
    die ".sparkle/ is not listed in .gitignore - add it before generating keys"
else
    info ".sparkle/ is listed in .gitignore - safe to continue"
fi

GENERATE_KEYS="$(require_sparkle_tool generate_keys)"
detail "Using ${GENERATE_KEYS}"

mkdir -p "$SPARKLE_DIR"
chmod 700 "$SPARKLE_DIR"

print_public_key() {
    local key
    key="$("$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -p 2>/dev/null || true)"
    printf '%s\n' "$key"
}

if [[ "$PRINT_ONLY" == true ]]; then
    PUBLIC_KEY="$(print_public_key)"
    [[ -n "$PUBLIC_KEY" ]] || die "no key found in the keychain for account '${SPARKLE_KEY_ACCOUNT}'"
    printf '%s\n' "$PUBLIC_KEY"
    exit 0
fi

if [[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
    step "Key pair already exists"
    info "Private key: ${SPARKLE_PRIVATE_KEY_FILE}"
    PUBLIC_KEY="$(cat "$SPARKLE_PUBLIC_KEY_FILE" 2>/dev/null || print_public_key)"
else
    step "Generating EdDSA key pair (the keychain may ask for permission)"
    "$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" >/dev/null \
        || die "generate_keys failed - allow keychain access and try again"

    rm -f "$SPARKLE_PRIVATE_KEY_FILE"
    "$GENERATE_KEYS" --account "$SPARKLE_KEY_ACCOUNT" -x "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null \
        || die "could not export the private key from the keychain"
    chmod 600 "$SPARKLE_PRIVATE_KEY_FILE"

    PUBLIC_KEY="$(print_public_key)"
    [[ -n "$PUBLIC_KEY" ]] || die "could not read the public key back from the keychain"
    info "Private key: ${SPARKLE_PRIVATE_KEY_FILE}"
fi

[[ -n "${PUBLIC_KEY:-}" ]] || die "could not determine the public key"
printf '%s\n' "$PUBLIC_KEY" > "$SPARKLE_PUBLIC_KEY_FILE"
chmod 644 "$SPARKLE_PUBLIC_KEY_FILE"
info "Public key:  ${SPARKLE_PUBLIC_KEY_FILE}"

step "Public key"
printf '%s\n\n' "$PUBLIC_KEY"

step "Next steps"
info "1. Put this in macos/${APP_NAME}/Info.plist:"
printf '\n       <key>SUPublicEDKey</key>\n       <string>%s</string>\n\n' "$PUBLIC_KEY"
info "2. For GitHub Actions, add the repository secret SPARKLE_PRIVATE_KEY with"
info "   the contents of ${SPARKLE_PRIVATE_KEY_FILE#"${REPO_ROOT}/"}"
info "3. Never commit the private key. Keep a backup somewhere safe - losing it"
info "   means existing installs can no longer be updated."
