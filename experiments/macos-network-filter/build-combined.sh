#!/bin/bash
# Build isolated artifacts only. Never install a binary/app or activate a filter.
set -euo pipefail
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Combined native build requires Apple Silicon macOS" >&2; exit 1
fi
bash build-app.sh "$@"
mkdir -p .build/tools
repo=$(cd ../.. && pwd)
output="$PWD/.build/tools/greywall"
(cd "$repo" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o "$output" ./cmd/greywall)
echo "Isolated CLI: $PWD/.build/tools/greywall"
echo "Installed Greywall, Applications folder and network settings unchanged."
