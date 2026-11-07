#!/bin/bash
# Runs PRM-Install.sh against scratch BeamMP server folders: a fresh install,
# an update over an old install with leftovers, a renamed resources folder, a
# running server, a write that fails, and a folder that is not a server. The
# release workflow runs it on every build; Git Bash on Windows runs most of it.
#
#   bash installer/linux/test.sh dist/PRM-Install.sh package
installer=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
pkg=$(cd "$2" && pwd)
checks=0; fails=0
check() { checks=$((checks + 1)); if ! eval "$1"; then fails=$((fails + 1)); echo "FAIL: $2"; fi; }

root=$(mktemp -d)
trap 'chmod -R u+w "$root" 2>/dev/null; rm -rf "$root"' EXIT
config=$'Port = 30814\nMap = "/levels/gridmap_v2/info.json"\n'
new_server() { mkdir -p "$1"; printf '%s' "$2" > "$1/ServerConfig.toml"; }
# Every file the release has, at the same bytes, under one resources folder.
installed() {
  cmp -s "$pkg/Client/RaceManager.zip" "$1/Client/RaceManager.zip" || return 1
  for f in "$pkg"/Server/RaceManager/*.lua; do cmp -s "$f" "$1/Server/RaceManager/${f##*/}" || return 1; done
}
zip_with() {
  local py; py=$(command -v python3 || command -v python)
  "$py" -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for n in sys.argv[2:]: z.writestr(n, "x")
z.close()' "$@"
}
run() { bash "$installer" "$1" > "$root/out.txt" 2>&1; }

# --- A fresh server ----------------------------------------------------------
fresh="$root/fresh server"
new_server "$fresh" "$config"
check 'run "$fresh"' 'a fresh server installs'
check 'installed "$fresh/Resources"' 'with every file the release has'
check 'ls "$fresh"/_attic/install-none-to-*/install.log >/dev/null 2>&1' 'and a log of what it did'

# --- An update over an old install -------------------------------------------
up="$root/update"
new_server "$up" "$config"
res="$up/Resources"; plugin="$res/Server/RaceManager"
mkdir -p "$plugin/Data/results" "$res/Client" "$res/Server/RaceManager_old" "$res/Server/OtherPlugin"
printf 'OLD CLIENT' > "$res/Client/RaceManager.zip"
printf -- "-- old\nlocal RM_BUILD = '0.0.1'\n" > "$plugin/main.lua"
printf -- '-- gone from the release' > "$plugin/stale.lua"
printf '{"adminPassword": "theirs"}' > "$plugin/Data/config.json"
printf 'P1 somebody' > "$plugin/Data/results/race.txt"
printf "local RM_BUILD = '0.0.0'\nprint('[RaceManager] loaded')" > "$res/Server/RaceManager_old/main.lua"
printf "print('RM_ is not ours')" > "$res/Server/OtherPlugin/main.lua"
zip_with "$res/Client/RaceManager-v0.19.0.zip" lua/ge/extensions/raceManager.lua scripts/raceManager/modScript.lua
zip_with "$res/Client/RaceManager-cars.zip" vehicles/buggy/buggy.jbeam
check 'run "$up"' 'an old install updates'
check 'installed "$res"' 'to every file the release has'
check '! [ -e "$plugin/stale.lua" ]' 'a plugin file the release no longer has is moved out'
check '[ "$(cat "$plugin/Data/config.json")" = "{\"adminPassword\": \"theirs\"}" ] && [ "$(cat "$plugin/Data/results/race.txt")" = "P1 somebody" ]' 'Data is left alone'
check '! [ -e "$res/Client/RaceManager-v0.19.0.zip" ]' 'a second copy of the client is moved out'
check '[ -e "$res/Client/RaceManager-cars.zip" ]' 'a zip that only shares the name stays'
check '! [ -e "$res/Server/RaceManager_old" ] && [ -e "$res/Server/OtherPlugin/main.lua" ]' 'another Race Manager plugin moves out, other plugins stay'
attic=$(ls -d "$up"/_attic/install-0.0.1-to-* 2>/dev/null | head -n 1)
check '[ -n "$attic" ]' 'the attic folder names both versions'
check '[ "$(cat "$attic/Client/RaceManager.zip")" = "OLD CLIENT" ] && [ -e "$attic/Server/RaceManager/stale.lua" ] && [ -e "$attic/Client/RaceManager-v0.19.0.zip" ] && [ -e "$attic/Server/RaceManager_old/main.lua" ]' 'and holds everything it replaced or moved'
check 'run "$up"' 'installing the same release again works'

# --- A renamed resources folder ----------------------------------------------
renamed="$root/renamed"
new_server "$renamed" "$config"$'ResourceFolder = "Res"\n'
check 'run "$renamed" && installed "$renamed/Res"' 'ResourceFolder in ServerConfig.toml is followed'
check '! [ -e "$renamed/Resources" ]' 'and nothing goes to Resources'

# --- A running server (Linux only: it needs pgrep and /proc) -------------------
if command -v pgrep >/dev/null 2>&1 && [ -d /proc/self ]; then
  running="$root/running"
  new_server "$running" "$config"
  cp "$(command -v sleep)" "$running/BeamMP-Server"
  (cd "$running" && exec ./BeamMP-Server 30) &
  fake=$!
  sleep 0.5
  check '! run "$running"' 'a server that is running is refused'
  check '! [ -e "$running/Resources" ]' 'and nothing is written'
  kill "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
else
  echo "(skipped the running-server check: no pgrep here)"
fi

# --- A write that fails (not as root, which writes anywhere) --------------------
if [ "$(id -u)" != 0 ]; then
  locked="$root/locked"
  new_server "$locked" "$config"
  lres="$locked/Resources"
  mkdir -p "$lres/Server/RaceManager" "$lres/Client"
  printf 'OLD CLIENT' > "$lres/Client/RaceManager.zip"
  printf "local RM_BUILD = '0.0.1'" > "$lres/Server/RaceManager/main.lua"
  printf -- '-- old maps' > "$lres/Server/RaceManager/maps.lua"
  chmod a-w "$lres/Server/RaceManager/maps.lua"
  if ! ( : > "$lres/Server/RaceManager/maps.lua" ) 2>/dev/null; then
    check '! run "$locked"' 'a file that cannot be written stops the install'
    check '[ "$(cat "$lres/Client/RaceManager.zip")" = "OLD CLIENT" ] && [ "$(cat "$lres/Server/RaceManager/main.lua")" = "local RM_BUILD = '"'"'0.0.1'"'"'" ]' 'and every file is put back'
  else
    echo "(skipped the failed-write check: this system writes read-only files)"
  fi
  chmod u+w "$lres/Server/RaceManager/maps.lua"
fi

# --- Not a server ----------------------------------------------------------------
empty="$root/empty"
mkdir -p "$empty"
check '! run "$empty"' 'a folder that is not a BeamMP server is refused'
check '[ -z "$(ls -A "$empty")" ]' 'and left empty'

echo "installer test: $checks checks, $fails failures"
[ "$fails" -eq 0 ]
