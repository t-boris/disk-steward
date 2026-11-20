#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <major.minor.patch> [build_number]" >&2
    exit 1
fi

NEW_VERSION="$1"
if [[ ! "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must follow Semantic Versioning (MAJOR.MINOR.PATCH), got '$NEW_VERSION'." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$REPO_ROOT/VERSION"
SWIFT_VERSION_FILE="$REPO_ROOT/Sources/DiskStewardCore/DiskStewardVersion.swift"

if [[ $# -eq 2 ]]; then
    NEW_BUILD="$2"
else
    CURRENT_BUILD="$(sed -n 's/.*fallbackBuild = "\([0-9]*\)".*/\1/p' "$SWIFT_VERSION_FILE" | head -n 1)"
    NEW_BUILD="$(( ${CURRENT_BUILD:-0} + 1 ))"
fi

printf "%s\n" "$NEW_VERSION" > "$VERSION_FILE"

python3 - "$SWIFT_VERSION_FILE" "$NEW_VERSION" "$NEW_BUILD" <<'PY'
import re, sys
path, version, build = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    text = f.read()
text, n1 = re.subn(r'fallbackVersion = "[^"]+"', f'fallbackVersion = "{version}"', text)
text, n2 = re.subn(r'fallbackBuild = "[^"]+"', f'fallbackBuild = "{build}"', text)
if n1 != 1 or n2 != 1:
    raise SystemExit(f"Failed to update DiskStewardVersion.swift (n1={n1}, n2={n2})")
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

echo "Bumped Disk Steward version to $NEW_VERSION (build $NEW_BUILD)."
