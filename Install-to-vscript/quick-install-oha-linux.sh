#!/bin/bash

# Open Hyper AI (OHA) - Quick Install Script for Linux
# Creates a symbolic link from the Workshop download to the vscripts/bots folder.
# This lets the bot scripts load correctly in Custom Lobbies with Local Host.

# Check if the script is run as root (needed for symlink in some setups)
if [ "$EUID" -ne 0 ]; then
  echo "Requesting administrator privileges..."
  sudo "$0" "$@"
  exit
fi

# Common Steam install locations on Linux
steam_paths=(
  "$HOME/.steam/steam"
  "$HOME/.local/share/Steam"
  "$HOME/.steam/debian-installation"
)

steam_path=""
for p in "${steam_paths[@]}"; do
  if [ -d "$p/steamapps" ]; then
    steam_path="$p"
    break
  fi
done

if [ -z "$steam_path" ]; then
  echo "Steam folder not found. Checked:"
  for p in "${steam_paths[@]}"; do
    echo "  - $p"
  done
  echo ""
  echo "If Steam is installed in a custom location, edit this script"
  echo "and set steam_path manually."
  exit 1
fi

echo "Found Steam at: $steam_path"

# Define paths
dota_path="$steam_path/steamapps/common/dota 2 beta/game/dota/scripts/vscripts/bots"
workshop_path="$steam_path/steamapps/workshop/content/570/3246316298"

# Check if Dota 2 is installed
if [ ! -d "$steam_path/steamapps/common/dota 2 beta" ]; then
  echo "Dota 2 folder not found. Please ensure Dota 2 is installed and try again."
  exit 1
fi

# Check if Workshop item is downloaded
if [ ! -d "$workshop_path" ]; then
  echo "Workshop folder not found at:"
  echo "  $workshop_path"
  echo ""
  echo "Please subscribe to Open Hyper AI in the Steam Workshop first,"
  echo "then wait for the download to complete before running this script."
  exit 1
fi

# Get the current timestamp (format: YYYYMMDD_HHMMSS)
timestamp=$(date +"%Y%m%d_%H%M%S")

# Check if the bots folder already exists
if [ -d "$dota_path" ] || [ -L "$dota_path" ]; then
  if [ -L "$dota_path" ]; then
    echo "Existing symlink found, removing..."
    rm "$dota_path"
  else
    echo "Existing bots folder found, renaming to bots_old_$timestamp..."
    mv "$dota_path" "${dota_path}_old_$timestamp"
  fi
fi

# Create the parent directory if it doesn't exist
mkdir -p "$(dirname "$dota_path")"

# Copy workshop files (not symlink) so we can patch casing for Linux
echo "Copying bot scripts..."
echo "  From: $workshop_path"
echo "  To:   $dota_path"
cp -r "$workshop_path" "$dota_path"

if [ $? -eq 0 ]; then
  echo ""
  echo "Applying Linux case-sensitivity patch..."
  echo "(Linux filesystems are case-sensitive; Lua require paths must match filenames exactly)"

  # Use Python to safely lowercase filenames and Lua require paths.
  # Based on: github.com/ashoktamang/dota2bot-OpenHyperAI-linux-patcher
  python3 - "$dota_path" <<'PYEOF'
import os, sys, re

root = sys.argv[1]

# Step 1: Rename files/dirs to lowercase (bottom-up so children move first)
for dirpath, dirnames, filenames in os.walk(root, topdown=False):
    for name in filenames + dirnames:
        lower = name.lower()
        if name != lower:
            src = os.path.join(dirpath, name)
            dst = os.path.join(dirpath, lower)
            if not os.path.exists(dst):
                os.rename(src, dst)

# Step 2: Lowercase quoted paths in require/dofile/LinkLuaModifier calls
keywords = re.compile(r'\b(require|dofile|LinkLuaModifier)\b')
path_dirs = {'bots', 'botslib', 'funclib', 'funlib', 'fretbots', 'customize', 'buff'}

def lower_paths(line):
    if not keywords.search(line):
        return line
    def lower_match(m):
        s = m.group(0)
        q = s[0]
        inner = s[1:-1]
        # Only lowercase if it looks like a module path
        if '/' in inner or '\\' in inner or '.' in inner:
            return q + inner.lower() + q
        parts = inner.lower().split('.')
        if any(p in path_dirs for p in parts):
            return q + inner.lower() + q
        return s
    return re.sub(r'''(['"])[^'"]+\1''', lower_match, line)

for dirpath, _, filenames in os.walk(root):
    for fname in filenames:
        if not fname.endswith('.lua'):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
            lines = f.readlines()
        new_lines = [lower_paths(l) for l in lines]
        if new_lines != lines:
            with open(fpath, 'w', encoding='utf-8') as f:
                f.writelines(new_lines)

print("  Renamed files/dirs to lowercase")
print("  Patched Lua require paths to lowercase")
PYEOF

  if [ $? -ne 0 ]; then
    echo "Warning: Python3 not found or patch failed."
    echo "Install python3 and re-run, or apply the patch manually."
    echo "See: github.com/ashoktamang/dota2bot-OpenHyperAI-linux-patcher"
  else
    echo "Patch applied."
  fi
  echo ""
  echo "============================================"
  echo "  Install Succeeded!"
  echo "============================================"
  echo ""
  echo "You can now create a Custom Lobby with"
  echo "Local Host server to use OHA bot scripts."
else
  echo ""
  echo "============================================"
  echo "  Install Failed!"
  echo "============================================"
  echo ""
  echo "1. Ensure Dota 2 is installed and paths are correct."
  echo "2. Ensure you run this script with sudo."
  echo "3. Check file permissions on the Dota 2 folder."
fi

# Pause to keep the terminal open
read -p "Press Enter to exit..."
