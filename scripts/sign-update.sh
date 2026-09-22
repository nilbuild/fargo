#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
    cat <<EOF
Sign a ${APP_NAME} update archive with the Sparkle EdDSA key.

Usage: scripts/sign-update.sh [OPTIONS] <path-to-zip>

Options:
  --json               Print {"file": ..., "edSignature": ..., "length": ...}
  --signature-only     Print just the EdDSA signature
  --key-file PATH      Private key file (default: ${SPARKLE_PRIVATE_KEY_FILE#"${REPO_ROOT}/"})
  --help               Show this help

Default output, ready to paste into an appcast enclosure:
  sparkle:edSignature="..." length="..."

Key resolution:
  1. SPARKLE_PRIVATE_KEY   raw key contents, used by CI (never written to disk)
  2. --key-file PATH
  3. ${SPARKLE_PRIVATE_KEY_FILE#"${REPO_ROOT}/"}
EOF
}

FORMAT="attrs"
KEY_FILE="$SPARKLE_PRIVATE_KEY_FILE"
FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) FORMAT="json"; shift ;;
        --signature-only) FORMAT="signature"; shift ;;
        --key-file) KEY_FILE="${2:-}"; shift 2 ;;
        --key-file=*) KEY_FILE="${1#*=}"; shift ;;
        --help|-h) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *)
            [[ -z "$FILE" ]] || die "only one file can be signed at a time"
            FILE="$1"
            shift
            ;;
    esac
done

[[ -n "$FILE" ]] || { usage >&2; die "no file given"; }
[[ -f "$FILE" ]] || die "file not found: ${FILE}"

SIGN_UPDATE="$(require_sparkle_tool sign_update)"

SIGNATURE=""
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # '-' reads the key from stdin, so it never hits disk or the process list.
    SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" -p --ed-key-file - "$FILE")"
elif [[ -f "$KEY_FILE" ]]; then
    SIGNATURE="$("$SIGN_UPDATE" -p --ed-key-file "$KEY_FILE" "$FILE")"
else
    die "no Sparkle private key: set SPARKLE_PRIVATE_KEY or run scripts/setup-sparkle-keys.sh"
fi

SIGNATURE="$(printf '%s' "$SIGNATURE" | tr -d '[:space:]')"
[[ -n "$SIGNATURE" ]] || die "sign_update produced an empty signature"

LENGTH="$(file_size "$FILE")"

case "$FORMAT" in
    json)
        printf '{"file":"%s","edSignature":"%s","length":%s}\n' "$(basename "$FILE")" "$SIGNATURE" "$LENGTH"
        ;;
    signature)
        printf '%s\n' "$SIGNATURE"
        ;;
    *)
        printf 'sparkle:edSignature="%s" length="%s"\n' "$SIGNATURE" "$LENGTH"
        ;;
esac
