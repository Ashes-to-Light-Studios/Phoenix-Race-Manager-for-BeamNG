#!/bin/bash
# Phoenix Race Manager @VERSION@: the installer for a BeamMP server on Linux.
#
#   bash PRM-Install.sh                  the server in this folder
#   bash PRM-Install.sh /path/to/server  that server
#
# ONE FILE: the release is packed onto the end of this script (build.sh). It
# copies what it replaces into _attic/, writes Resources/Client/RaceManager.zip
# and the plugin's .lua files, and never touches Resources/Server/RaceManager/
# Data. The rules are the in-game updater's (server/RaceManager/update.lua).
#
# Run it with bash, never piped into bash: it reads its own file to find the
# release. No set -u: bash before 4.4 calls an empty array unbound.
VERSION='@VERSION@'

say() { printf '%s\n' "$*"; }
die() { printf 'PRM: %s\n' "$*" >&2; exit 1; }

# A server folder: its config, or its binary before a first run writes the config.
is_server() { [ -f "$1/ServerConfig.toml" ] || [ -f "$1/BeamMP-Server" ]; }

server=$1
if [ -z "$server" ]; then
  for d in "$PWD" "$(cd "$(dirname "$0")" && pwd)"; do
    if is_server "$d"; then server=$d; break; fi
  done
fi
if [ -z "$server" ]; then
  found=$(find "$HOME" /opt /srv /home -maxdepth 3 -name ServerConfig.toml 2>/dev/null \
    | while read -r f; do dirname "$f"; done | sort -u)
  count=$(printf '%s\n' "$found" | grep -c .)
  if [ "$count" -eq 1 ]; then
    server=$found
  elif [ "$count" -gt 1 ]; then
    die "several BeamMP servers found. Run it with the one to install into:
$(printf '%s\n' "$found" | sed "s|^|  bash $0 |")"
  else
    die "no BeamMP server here. Run it in the server's folder, or: bash $0 /path/to/server"
  fi
fi
[ -d "$server" ] || die "$server is not a folder"
is_server "$server" || die "$server is not a BeamMP server folder: it has neither ServerConfig.toml nor BeamMP-Server"
server=$(cd "$server" && pwd)

# BeamMP reloads a changed plugin on the spot, which ends any session in
# progress, and keeps offering the old client until it restarts. -x: a
# server folder called BeamMP-Server puts the name in this script's own path.
if command -v pgrep >/dev/null 2>&1; then
  for pid in $(pgrep -x BeamMP-Server 2>/dev/null); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
    if [ "$cwd" = "$server" ] || [ "${exe%/*}" = "$server" ]; then
      die "the BeamMP server in $server is running (pid $pid). Stop it, then run this again."
    fi
  done
fi

# ResourceFolder from ServerConfig.toml: a server may have renamed it.
res=$(sed -n 's/^[[:space:]]*ResourceFolder[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$server/ServerConfig.toml" 2>/dev/null | head -n 1)
res=${res:-Resources}
case $res in /*) ;; *) res="$server/$res" ;; esac
client="$res/Client"
plugin="$res/Server/RaceManager"

tmp=$(mktemp -d 2>/dev/null) || die "could not make a temporary folder"
trap 'rm -rf "$tmp"' EXIT
start=$(awk '/^__PRM_PAYLOAD__$/ { print NR + 1; exit }' "$0")
[ -n "$start" ] || die "this installer has no release in it. Download it again."
tail -n +"$start" "$0" | base64 -d 2>/dev/null | tar -xzf - -C "$tmp" 2>/dev/null \
  || die "this installer is damaged. Download it again."
[ -f "$tmp/Client/RaceManager.zip" ] && [ -f "$tmp/Server/RaceManager/main.lua" ] \
  || die "this installer is damaged. Download it again."

old=$(sed -n "s/^local RM_BUILD = '\([^']*\)'.*/\1/p" "$plugin/main.lua" 2>/dev/null | head -n 1)
attic="$server/_attic/install-${old:-none}-to-${VERSION}_$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$attic/Client" "$attic/Server/RaceManager" "$client" "$plugin" \
  || die "could not make folders in $server"

# Every change is recorded so a failure can put each file back.
kinds=(); froms=(); tos=()
written=(); moved=(); notes=()
remember() { kinds+=("$1"); froms+=("$2"); tos+=("$3"); }
rollback() {
  local i lost=0
  for (( i = ${#kinds[@]} - 1; i >= 0; i-- )); do
    if [ "${kinds[i]}" = restore ]; then cp -p "${froms[i]}" "${tos[i]}" 2>/dev/null || lost=1
    else rm -f "${tos[i]}" 2>/dev/null || lost=1; fi
  done
  return $lost
}
fail() {
  if rollback; then die "$1. Everything was put back as it was."
  else die "$1. Some files could not be put back: copy them from $attic."; fi
}

# Write one file, backing up what it replaces. Read back: a full disk writes
# short without saying so.
put() {
  if [ -f "$2" ]; then
    cp -p "$2" "$3" 2>/dev/null || fail "could not back up $2"
    remember restore "$3" "$2"
  else
    remember remove "" "$2"
  fi
  { cp "$1" "$2" && cmp -s "$1" "$2"; } 2>/dev/null || fail "could not write $2"
  written+=("${2#"$server"/}")
}

put "$tmp/Client/RaceManager.zip" "$client/RaceManager.zip" "$attic/Client/RaceManager.zip"
for f in "$tmp"/Server/RaceManager/*.lua; do
  put "$f" "$plugin/${f##*/}" "$attic/Server/RaceManager/${f##*/}"
done
# A plugin file this release no longer has: BeamMP runs every .lua in the
# folder, so it would keep running beside the new ones.
for f in "$plugin"/*.lua; do
  [ -f "$f" ] || continue
  n=${f##*/}
  [ -f "$tmp/Server/RaceManager/$n" ] && continue
  cp -p "$f" "$attic/Server/RaceManager/$n" 2>/dev/null || fail "could not back up $f"
  remember restore "$attic/Server/RaceManager/$n" "$f"
  rm -f "$f" 2>/dev/null || fail "could not remove $f"
  moved+=("${f#"$server"/} (not part of PRM $VERSION)")
done

# Older copies of PRM that would run beside this one, moved, never deleted.
move_out() {
  if mkdir -p "$(dirname "$2")" && mv "$1" "$2" 2>/dev/null; then moved+=("${1#"$server"/} ($3)")
  else notes+=("Could not move ${1#"$server"/} ($3): move it out yourself."); fi
}
# Unzip or Python reads what is inside; with neither, the name has to do.
holds_client() {
  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$1" 2>/dev/null | grep -qx 'lua/ge/extensions/raceManager.lua'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; sys.exit("lua/ge/extensions/raceManager.lua" not in zipfile.ZipFile(sys.argv[1]).namelist())' "$1" 2>/dev/null
  fi
}
# A second client zip: BeamMP sends every zip in Client to every player.
shopt -s nocaseglob nullglob
for z in "$client"/RaceManager*.zip; do
  [ "${z##*/}" = RaceManager.zip ] && continue
  holds_client "$z" && move_out "$z" "$attic/Client/${z##*/}" "a second copy of the PRM client"
done
shopt -u nocaseglob
# Another plugin folder: BeamMP runs every folder in Server.
for d in "$res"/Server/*/; do
  d=${d%/}
  [ "$d" -ef "$plugin" ] && continue
  [ -f "$d/main.lua" ] && grep -q 'RM_BUILD' "$d/main.lua" && grep -qF '[RaceManager]' "$d/main.lua" \
    && move_out "$d" "$attic/Server/${d##*/}" "another Race Manager plugin"
done
# Packages up to 0.6.0 spelled the folders in lower case, which BeamMP never reads.
if [ -d "$res/server/RaceManager" ] && ! [ "$res/server" -ef "$res/Server" ]; then
  move_out "$res/server/RaceManager" "$attic/server/RaceManager" "an old install in the lower-case folder"
fi
if [ -f "$res/client/RaceManager.zip" ] && ! [ "$res/client" -ef "$res/Client" ]; then
  move_out "$res/client/RaceManager.zip" "$attic/client/RaceManager.zip" "an old install in the lower-case folder"
fi
shopt -u nullglob

{
  if [ -z "$old" ]; then was=''; elif [ "$old" = "$VERSION" ]; then was=' (installed again)'; else was=" (it was $old)"; fi
  say "Phoenix Race Manager $VERSION is installed in $server$was."
  say ""
  say "Written:"
  for w in "${written[@]}"; do say "  $w"; done
  if [ ${#moved[@]} -gt 0 ]; then
    say "Moved out:"
    for m in "${moved[@]}"; do say "  $m"; done
  fi
  for n in "${notes[@]}"; do say "$n"; done
  say "Anything replaced is in ${attic#"$server"/}."
  say "Tracks, results and settings in ${plugin#"$server"/}/Data were not touched."
  say ""
  say "Next:"
  say "  1. Start the server, or restart it if it is running."
  say "  2. Players get PRM as they join. Each driver adds Phoenix Race Manager (PRM)"
  say "     once from HUD Apps (search PRM)."
  if [ -z "$old" ]; then
    say "  3. Log in on the app's admin bar with the password from the README, then set"
    say "     your own on the Admin tab."
  fi
  say "Later releases install from the app's Admin tab: Update and restart."
} | tee "$attic/install.log"
exit 0
