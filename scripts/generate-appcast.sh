#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh source-path=SCRIPTDIR
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

APPCAST_PATH="${REPO_ROOT}/appcast.xml"
VERSION=""
BUILD=""
ZIP_PATH=""
NOTES_FILE=""
NOTES_URL=""
DOWNLOAD_URL_BASE="$DOWNLOAD_URL_BASE_DEFAULT"
DOWNLOAD_URL=""
SIGNATURE=""
LENGTH=""

usage() {
    cat <<EOF
Add a release to the ${APP_NAME} Sparkle appcast.

Usage: scripts/generate-appcast.sh --zip PATH [OPTIONS]

Options:
  --zip PATH                 Release ZIP to sign and link (required)
  --version X.Y.Z            Marketing version (default: from project.pbxproj)
  --build N                  Build number, becomes sparkle:version (default: from project.pbxproj)
  --notes-file PATH          Release notes (Markdown or HTML) embedded in the item
  --notes-url URL            Release notes link instead of embedded notes
  --appcast PATH             Appcast file to create or update (default: appcast.xml)
  --download-url-base URL    Release download base (default: ${DOWNLOAD_URL_BASE_DEFAULT})
  --download-url URL         Full enclosure URL, overrides --download-url-base
  --signature SIG            Use this EdDSA signature instead of signing the ZIP
  --length BYTES             Use this length instead of the ZIP's size
  --min-system-version V     Minimum macOS version (default: ${MIN_SYSTEM_VERSION})
  --help                     Show this help

The enclosure URL defaults to:
  <download-url-base>/v<version>/<zip filename>

The new item is prepended, so the newest release is first; an item with the same
sparkle:version is replaced, which makes re-runs idempotent. Existing items are
kept as they are.

Signing uses SPARKLE_PRIVATE_KEY when set, otherwise .sparkle/eddsa_private_key
(see scripts/sign-update.sh).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --zip) ZIP_PATH="${2:-}"; shift 2 ;;
        --zip=*) ZIP_PATH="${1#*=}"; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --build) BUILD="${2:-}"; shift 2 ;;
        --build=*) BUILD="${1#*=}"; shift ;;
        --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
        --notes-file=*) NOTES_FILE="${1#*=}"; shift ;;
        --notes-url) NOTES_URL="${2:-}"; shift 2 ;;
        --notes-url=*) NOTES_URL="${1#*=}"; shift ;;
        --appcast) APPCAST_PATH="${2:-}"; shift 2 ;;
        --appcast=*) APPCAST_PATH="${1#*=}"; shift ;;
        --download-url-base) DOWNLOAD_URL_BASE="${2:-}"; shift 2 ;;
        --download-url-base=*) DOWNLOAD_URL_BASE="${1#*=}"; shift ;;
        --download-url) DOWNLOAD_URL="${2:-}"; shift 2 ;;
        --download-url=*) DOWNLOAD_URL="${1#*=}"; shift ;;
        --signature) SIGNATURE="${2:-}"; shift 2 ;;
        --signature=*) SIGNATURE="${1#*=}"; shift ;;
        --length) LENGTH="${2:-}"; shift 2 ;;
        --length=*) LENGTH="${1#*=}"; shift ;;
        --min-system-version) MIN_SYSTEM_VERSION="${2:-}"; shift 2 ;;
        --min-system-version=*) MIN_SYSTEM_VERSION="${1#*=}"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

require_cmd python3

[[ -n "$ZIP_PATH" ]] || { usage >&2; die "--zip is required"; }
[[ -f "$ZIP_PATH" ]] || die "ZIP not found: ${ZIP_PATH}"
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "notes file not found: ${NOTES_FILE}"
if [[ -n "$NOTES_FILE" && -n "$NOTES_URL" ]]; then
    die "--notes-file and --notes-url are mutually exclusive"
fi

[[ -n "$VERSION" ]] || VERSION="$(get_version)"
[[ -n "$BUILD" ]] || BUILD="$(get_build_number)"
validate_version "$VERSION"

if [[ -z "$DOWNLOAD_URL" ]]; then
    DOWNLOAD_URL="${DOWNLOAD_URL_BASE%/}/v${VERSION}/$(basename "$ZIP_PATH")"
fi

step "Signing ${ZIP_PATH##*/}"
if [[ -z "$SIGNATURE" ]]; then
    SIGNATURE="$("${SCRIPTS_DIR}/sign-update.sh" --signature-only "$ZIP_PATH")"
fi
[[ -n "$LENGTH" ]] || LENGTH="$(file_size "$ZIP_PATH")"
detail "signature ${SIGNATURE:0:24}… length ${LENGTH}"

step "Updating appcast"
info "File:    ${APPCAST_PATH}"
info "Item:    ${VERSION} (sparkle:version ${BUILD})"
info "Enclosure: ${DOWNLOAD_URL}"

mkdir -p "$(dirname "$APPCAST_PATH")"

APPCAST_PATH="$APPCAST_PATH" \
APP_NAME="$APP_NAME" \
FEED_VERSION="$VERSION" \
FEED_BUILD="$BUILD" \
FEED_SIGNATURE="$SIGNATURE" \
FEED_LENGTH="$LENGTH" \
FEED_URL="$DOWNLOAD_URL" \
FEED_MIN_SYSTEM="$MIN_SYSTEM_VERSION" \
FEED_NOTES_FILE="$NOTES_FILE" \
FEED_NOTES_URL="$NOTES_URL" \
FEED_PUBDATE="$(rfc822_date)" \
FEED_LINK="$(printf 'https://github.com/%s' "$GITHUB_REPO")" \
python3 - <<'PY'
import html
import os
import re
import sys
from xml.dom import minidom

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

path = os.environ["APPCAST_PATH"]
app = os.environ["APP_NAME"]
version = os.environ["FEED_VERSION"]
build = os.environ["FEED_BUILD"]
signature = os.environ["FEED_SIGNATURE"]
length = os.environ["FEED_LENGTH"]
url = os.environ["FEED_URL"]
min_system = os.environ["FEED_MIN_SYSTEM"]
notes_file = os.environ.get("FEED_NOTES_FILE") or ""
notes_url = os.environ.get("FEED_NOTES_URL") or ""
pub_date = os.environ["FEED_PUBDATE"]
link = os.environ["FEED_LINK"]

SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{ns}">
  <channel>
    <title>{app}</title>
    <link>{link}</link>
    <description>Most recent {app} updates.</description>
    <language>en</language>
  </channel>
</rss>
""".format(ns=SPARKLE_NS, app=html.escape(app), link=html.escape(link))


def markdown_to_html(text):
    """Small Markdown subset -> HTML, enough for release notes."""
    out = []
    in_list = False

    def inline(s):
        s = html.escape(s)
        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
        s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
        s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"(?<![*\w])\*([^*]+)\*(?!\w)", r"<em>\1</em>", s)
        return s

    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        bullet = re.match(r"^[-*+]\s+(.*)$", stripped)
        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)

        if bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append("<li>%s</li>" % inline(bullet.group(1)))
            continue

        if in_list:
            out.append("</ul>")
            in_list = False

        if not stripped:
            continue
        if heading:
            level = min(len(heading.group(1)) + 1, 6)
            out.append("<h%d>%s</h%d>" % (level, inline(heading.group(2)), level))
        else:
            out.append("<p>%s</p>" % inline(stripped))

    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def looks_like_html(text):
    return bool(re.search(r"<(p|ul|ol|li|h[1-6]|div|br)\b", text, re.I))


if os.path.exists(path):
    with open(path, "rb") as fh:
        doc = minidom.parse(fh)
else:
    doc = minidom.parseString(SKELETON)

rss = doc.documentElement
if rss.tagName != "rss":
    sys.exit("error: %s is not an RSS document" % path)
if not rss.getAttribute("xmlns:sparkle"):
    rss.setAttribute("xmlns:sparkle", SPARKLE_NS)

channels = rss.getElementsByTagName("channel")
if not channels:
    sys.exit("error: %s has no <channel>" % path)
channel = channels[0]


def strip_blank_text(node):
    for child in list(node.childNodes):
        if child.nodeType == child.TEXT_NODE and not child.data.strip():
            node.removeChild(child)
        elif child.nodeType == child.ELEMENT_NODE:
            strip_blank_text(child)


strip_blank_text(channel)


def text_element(name, value):
    el = doc.createElement(name)
    el.appendChild(doc.createTextNode(value))
    return el


item = doc.createElement("item")
item.appendChild(text_element("title", "Version %s" % version))
item.appendChild(text_element("pubDate", pub_date))
item.appendChild(text_element("sparkle:version", build))
item.appendChild(text_element("sparkle:shortVersionString", version))
item.appendChild(text_element("sparkle:minimumSystemVersion", min_system))

if notes_url:
    item.appendChild(text_element("sparkle:releaseNotesLink", notes_url))
elif notes_file:
    with open(notes_file, "r", encoding="utf-8") as fh:
        notes = fh.read().strip()
    if notes:
        body = notes if looks_like_html(notes) else markdown_to_html(notes)
        description = doc.createElement("description")
        description.appendChild(doc.createCDATASection(body))
        item.appendChild(description)

enclosure = doc.createElement("enclosure")
enclosure.setAttribute("url", url)
enclosure.setAttribute("length", str(length))
enclosure.setAttribute("type", "application/octet-stream")
enclosure.setAttribute("sparkle:edSignature", signature)
item.appendChild(enclosure)

for existing in channel.getElementsByTagName("item"):
    versions = existing.getElementsByTagName("sparkle:version")
    if versions and versions[0].firstChild and versions[0].firstChild.data.strip() == build:
        channel.removeChild(existing)

first_item = None
for child in channel.childNodes:
    if child.nodeType == child.ELEMENT_NODE and child.tagName == "item":
        first_item = child
        break

if first_item is not None:
    channel.insertBefore(item, first_item)
else:
    channel.appendChild(item)

strip_blank_text(doc.documentElement)
pretty = doc.toprettyxml(indent="  ", encoding="utf-8").decode("utf-8")
lines = [line for line in pretty.split("\n") if line.strip()]
with open(path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY

step "Done"
info "Appcast written to ${APPCAST_PATH}"
