#!/usr/bin/env bash
# Source this file. Install only inside the checkout; do not use unpinned brew.
set -euo pipefail
XCODEGEN_VERSION=2.44.1
XCODEGEN_SHA256=a2e905fb68446e9bb4008cdfe2e13e3f176d0cbcca828b71770f8e53fca91b73
XCODEGEN_TOOLS_DIR="$PWD/build/tools/xcodegen-$XCODEGEN_VERSION"
mkdir -p "$XCODEGEN_TOOLS_DIR"
curl --fail --location --retry 3 \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" \
  --output "$XCODEGEN_TOOLS_DIR/xcodegen.zip"
printf '%s  %s\n' "$XCODEGEN_SHA256" "$XCODEGEN_TOOLS_DIR/xcodegen.zip" | shasum -a 256 --check
unzip -oq "$XCODEGEN_TOOLS_DIR/xcodegen.zip" -d "$XCODEGEN_TOOLS_DIR"
XCODEGEN_BIN=$(python3 - "$XCODEGEN_TOOLS_DIR" <<'PY'
import pathlib, sys
matches = [p for p in pathlib.Path(sys.argv[1]).rglob('xcodegen') if p.is_file() and p.parent.name == 'bin']
assert len(matches) == 1, f'Expected one XcodeGen executable, found {len(matches)}'
print(matches[0])
PY
)
export XCODEGEN_BIN
"$XCODEGEN_BIN" --version | tee "$XCODEGEN_TOOLS_DIR/version.txt"
"$XCODEGEN_BIN" --version | grep -Eq '(^| )2\.44\.1($| )'
