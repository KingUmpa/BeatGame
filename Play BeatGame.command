#!/bin/zsh
# Double-click to play the game from this folder (macOS). Needs LÖVE 11.5 in
# ~/Applications or /Applications (dist/cache/love-11.5-macos.zip unzips to it).
cd "$(dirname "$0")"
for app in "$HOME/Applications/love.app" "/Applications/love.app"; do
  if [ -x "$app/Contents/MacOS/love" ]; then
    "$app/Contents/MacOS/love" . "$@" &
    disown
    exit 0
  fi
done
echo "LÖVE not found. Unzip dist/cache/love-11.5-macos.zip into ~/Applications and try again."
read -k 1 "?Press any key to close."
