#!/bin/bash
# Builds PRM-Install.sh: install.sh with the package packed onto its end.
#
#   bash installer/linux/build.sh package dist/PRM-Install.sh
#
# The package folder is what tools/deploy.py --build-only writes: Client/ and
# Server/ (and LICENSE, in the release workflow). tar and base64 are on every
# Linux, which is why the payload is not a zip.
set -euo pipefail
pkg=$1
out=$2
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n "s/^local RM_BUILD = '\([^']*\)'.*/\1/p" "$pkg/Server/RaceManager/main.lua" | head -n 1)
[ -n "$version" ] || { echo "no RM_BUILD in $pkg/Server/RaceManager/main.lua" >&2; exit 1; }
[ -f "$pkg/Client/RaceManager.zip" ] || { echo "no Client/RaceManager.zip in $pkg" >&2; exit 1; }
parts=(Client Server)
[ -f "$pkg/LICENSE" ] && parts+=(LICENSE)
{
  sed "s/@VERSION@/$version/g" "$here/install.sh"
  echo '__PRM_PAYLOAD__'
  tar -czf - -C "$pkg" "${parts[@]}" | base64
} > "$out"
chmod +x "$out"
echo "built $out: Phoenix Race Manager $version, $(wc -c < "$out") bytes"
