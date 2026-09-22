#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # these are consumed by the scripts that source this file

APP_NAME="Streamif"
SCHEME="Streamif"
BUNDLE_ID="com.streamif.app"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_LIB_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/scripts"
XCODE_PROJECT="${REPO_ROOT}/macos/${APP_NAME}.xcodeproj"
PBXPROJ="${XCODE_PROJECT}/project.pbxproj"
ENTITLEMENTS="${REPO_ROOT}/macos/${APP_NAME}/${APP_NAME}.entitlements"

SPARKLE_DIR="${REPO_ROOT}/.sparkle"
SPARKLE_TOOLS_DIR="${SPARKLE_DIR}/tools"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_DIR}/eddsa_private_key"
SPARKLE_PUBLIC_KEY_FILE="${SPARKLE_DIR}/eddsa_public_key"
SPARKLE_TOOLS_VERSION="${SPARKLE_TOOLS_VERSION:-2.10.0}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-streamif}"

GITHUB_REPO="${GITHUB_REPO:-nilbuild/streamif}"
DOWNLOAD_URL_BASE_DEFAULT="https://github.com/${GITHUB_REPO}/releases/download"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-14.0}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-6QG84AK9XP}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-notarytool-profile}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_YELLOW="" C_BLUE=""
fi

step() {
    printf '\n%s==> %s%s\n' "${C_BLUE}${C_BOLD}" "$*" "${C_RESET}"
}

info() {
    printf '    %s\n' "$*"
}

detail() {
    printf '    %s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"
}

warn() {
    printf '%swarning:%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2
}

die() {
    printf '%serror:%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2
    exit 1
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

get_version() {
    local v
    v="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ}" | head -1)"
    [[ -n "$v" ]] || die "could not read MARKETING_VERSION from ${PBXPROJ}"
    printf '%s\n' "$v"
}

get_build_number() {
    local b
    b="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);.*/\1/p' "${PBXPROJ}" | head -1)"
    [[ -n "$b" ]] || die "could not read CURRENT_PROJECT_VERSION from ${PBXPROJ}"
    printf '%s\n' "$b"
}

validate_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$1' (expected X.Y.Z)"
}

set_version() {
    local new="$1"
    validate_version "$new"
    sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1${new};/g" "${PBXPROJ}"
}

set_build_number() {
    local new="$1"
    [[ "$new" =~ ^[0-9]+$ ]] || die "invalid build number '$new'"
    sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[^;]*;/\1${new};/g" "${PBXPROJ}"
}

bump_version() {
    local bump_type="$1"
    local current_version current_build major minor patch new_version new_build

    current_version="$(get_version)"
    current_build="$(get_build_number)"
    validate_version "$current_version"

    IFS='.' read -r major minor patch <<< "$current_version"

    case "$bump_type" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) die "invalid bump type '$bump_type' (use major, minor or patch)" ;;
    esac

    new_version="${major}.${minor}.${patch}"
    new_build=$((current_build + 1))

    set_version "$new_version"
    set_build_number "$new_build"

    info "Version: ${current_version} -> ${new_version} (build ${current_build} -> ${new_build})"
}

sparkle_tool() {
    local name="$1" candidate

    if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "${SPARKLE_BIN_DIR}/${name}" ]]; then
        printf '%s\n' "${SPARKLE_BIN_DIR}/${name}"
        return 0
    fi

    if [[ -x "${SPARKLE_TOOLS_DIR}/bin/${name}" ]]; then
        printf '%s\n' "${SPARKLE_TOOLS_DIR}/bin/${name}"
        return 0
    fi

    if candidate="$(command -v "$name" 2>/dev/null)"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    local derived="${HOME}/Library/Developer/Xcode/DerivedData"
    if [[ -d "$derived" ]]; then
        candidate="$(find "$derived" -type f -name "$name" -path '*[Ss]parkle*' 2>/dev/null | head -1)"
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi

    return 1
}

download_sparkle_tools() {
    require_cmd curl
    require_cmd tar

    local url tmp
    url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_TOOLS_VERSION}/Sparkle-${SPARKLE_TOOLS_VERSION}.tar.xz"
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand tmp now, it is fixed for the life of the function
    trap "rm -rf '${tmp}'" RETURN

    step "Downloading Sparkle ${SPARKLE_TOOLS_VERSION} release tools"
    detail "$url"
    curl -fsSL --retry 3 --retry-delay 2 -o "${tmp}/Sparkle.tar.xz" "$url" \
        || die "failed to download Sparkle tools from ${url}"

    tar -xJf "${tmp}/Sparkle.tar.xz" -C "${tmp}" ./bin/generate_keys ./bin/sign_update \
        || die "failed to extract Sparkle tools from the release archive"

    mkdir -p "${SPARKLE_TOOLS_DIR}/bin"
    cp "${tmp}/bin/generate_keys" "${tmp}/bin/sign_update" "${SPARKLE_TOOLS_DIR}/bin/"
    chmod +x "${SPARKLE_TOOLS_DIR}/bin/generate_keys" "${SPARKLE_TOOLS_DIR}/bin/sign_update"
    info "Installed to ${SPARKLE_TOOLS_DIR}/bin"
}

require_sparkle_tool() {
    local name="$1" path
    if path="$(sparkle_tool "$name")"; then
        printf '%s\n' "$path"
        return 0
    fi
    download_sparkle_tools >&2
    path="$(sparkle_tool "$name")" || die "Sparkle tool '${name}' is still missing after download"
    printf '%s\n' "$path"
}

# Sparkle's Autoupdate ships ad-hoc signed inside the XCFramework, which the
# notary service rejects, so codesign has to be pointed at it directly.
nested_helper_executables() {
    local app="$1" path base grandparent kind
    while IFS= read -r path; do
        case "$path" in
            */Contents/MacOS/*|*.dylib) continue ;;
        esac
        base="$(basename "$path")"
        # A framework's own binary is signed with the framework bundle.
        grandparent="$(basename "$(dirname "$(dirname "$(dirname "$path")")")")"
        if [[ "$grandparent" == "${base}.framework" ]]; then
            continue
        fi
        # Captured, not piped into grep: with `set -o pipefail` an early-exiting
        # grep kills the producer with SIGPIPE and the pipeline reports failure.
        kind="$(file -b "$path" 2>/dev/null || true)"
        case "$kind" in
            Mach-O*) printf '%s\n' "$path" ;;
        esac
    done < <(find "${app}/Contents" -type f -perm +111 2>/dev/null)
}

# Signs innermost first. Nested code gets the hardened runtime but none of the
# app's entitlements; only the outer app gets those.
resign_app() {
    local app="$1" identity="$2" entitlements="${3:-}"
    local component

    while IFS= read -r component; do
        [[ -n "$component" ]] || continue
        detail "helper  ${component#"${app}/Contents/"}"
        codesign --force --options runtime --timestamp --sign "$identity" "$component"
    done < <(nested_helper_executables "$app")

    while IFS= read -r component; do
        [[ -n "$component" ]] || continue
        detail "bundle  ${component#"${app}/Contents/"}"
        codesign --force --options runtime --timestamp --sign "$identity" "$component"
    done < <(find "${app}/Contents" -depth ! -type l \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) 2>/dev/null)

    detail "app     $(basename "$app")"
    if [[ -n "$entitlements" ]]; then
        codesign --force --options runtime --timestamp \
            --entitlements "$entitlements" --sign "$identity" "$app"
    else
        codesign --force --options runtime --timestamp --sign "$identity" "$app"
    fi
}

assert_no_adhoc_signatures() {
    local app="$1" component description
    local adhoc=()

    while IFS= read -r component; do
        [[ -n "$component" ]] || continue
        description="$(codesign -dvv "$component" 2>&1 || true)"
        case "$description" in
            *"Signature=adhoc"*) adhoc+=("${component#"${app}/"}") ;;
        esac
    done < <(
        nested_helper_executables "$app"
        find "${app}/Contents" -depth ! -type l \
            \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.dylib' \) 2>/dev/null
        printf '%s\n' "$app"
    )

    if (( ${#adhoc[@]} > 0 )); then
        printf '%s\n' "${adhoc[@]}" >&2
        die "the components above are still ad-hoc signed and would fail notarization"
    fi
}

file_size() {
    stat -f%z "$1"
}

rfc822_date() {
    date "+%a, %d %b %Y %H:%M:%S %z"
}
